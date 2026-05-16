import Foundation

/// 把 `TestPlan` 中所有 phase 的 `MeasurementSpec` / `SeriesMeasurementSpec`
/// 序列化为 [JSON Schema Draft-07](http://json-schema.org/draft-07/schema)
/// 描述文档，供 BI / 看板 / 跨语言系统消费。
///
/// 内置 validator 到 schema keyword 的映射：
/// - `InRangeValidator`           → `minimum` / `maximum` (+ `exclusive*`)
/// - `EqualsValueValidator`       → `const`
/// - `RegexMeasurementValidator`  → `pattern` + `type: "string"`
/// - `WithinPercentValidator`     → `minimum` / `maximum`（按 ±percent% 计算）
/// - `OneOfValidator`             → `enum`
/// - `LengthEqualsValidator`      → `minLength`/`maxLength` 或 `minItems`/`maxItems`
///                                   （二者并写，消费方按 type 取）
/// - `NotEmptyMeasurementValidator` / `SetEqualsValidator` /
///   `MarginalRangeValidator` / `CustomMeasurementValidator` → 不映射，
///   但其 `label` 写入 `x-swifthtf-validators` 自定义扩展数组。
///
/// 因此"x-swifthtf-validators" 永远是无损副本（标签全在）；keyword 字段是
/// 标准 JSON Schema 工具能直接吃的子集。
///
/// 用法：
/// ```swift
/// let data = try plan.exportSchema()
/// try data.write(to: URL(fileURLWithPath: "plan.schema.json"))
/// ```
public extension TestPlan {
    /// 导出 JSON Schema 文档（已 prettyPrinted + sortedKeys，可直接落盘）。
    func exportSchema() throws -> Data {
        let object = exportSchemaObject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(object)
    }

    /// 直接拿到 schema 的 `AnyCodableValue` 树，方便嵌入其它结构 / 单元测试。
    func exportSchemaObject() -> AnyCodableValue {
        var properties: [String: AnyCodableValue] = [:]
        var phaseArguments: [AnyCodableValue] = []
        let allNodes = setupNodes + nodes + teardownNodes
        for node in allNodes {
            collectSchemaProperties(node: node, into: &properties)
            collectPhaseArguments(node: node, into: &phaseArguments)
        }
        var schema: [String: AnyCodableValue] = [
            "$schema": .string("http://json-schema.org/draft-07/schema#"),
            "title": .string(name),
            "type": .string("object"),
            "properties": .object(properties),
        ]
        // 显式声明本 schema 由 SwiftHTF 生成，便于 BI 识别
        schema["x-swifthtf-version"] = .string("0.3.0")
        if !phaseArguments.isEmpty {
            schema["x-swifthtf-arguments"] = .array(phaseArguments)
        }
        return .object(schema)
    }
}

/// 收集每个 phase 的 `arguments` 快照成 `{ phase, arguments }` 数组，
/// 写入 `x-swifthtf-arguments`。BI / 看板可据此列出参数化变体。
private func collectPhaseArguments(
    node: PhaseNode,
    into accumulator: inout [AnyCodableValue]
) {
    switch node {
    case let .phase(p):
        guard !p.arguments.isEmpty else { return }
        accumulator.append(.object([
            "phase": .string(p.definition.name),
            "arguments": .object(p.arguments),
        ]))
    case let .group(g):
        let all = g.setup + g.children + g.teardown
        for child in all {
            collectPhaseArguments(node: child, into: &accumulator)
        }
    case let .subtest(s):
        for child in s.nodes {
            collectPhaseArguments(node: child, into: &accumulator)
        }
    case .checkpoint:
        break
    }
}

/// 递归提取 PhaseNode 下所有 MeasurementSpec / SeriesMeasurementSpec
/// 并写入 properties。同名 spec 由后定义覆盖（与运行时 harvest 一致）。
/// 同时把每个 phase 的参数化输入（`Phase.arguments`）汇总到 x-swifthtf-arguments
/// 顶级数组里，方便 BI 看"哪些参数化变体存在"。
private func collectSchemaProperties(
    node: PhaseNode,
    into properties: inout [String: AnyCodableValue]
) {
    switch node {
    case let .phase(p):
        for spec in p.measurements {
            properties[spec.name] = schemaFor(measurement: spec)
        }
        for spec in p.series {
            properties[spec.name] = schemaFor(series: spec)
        }
    case let .group(g):
        let all = g.setup + g.children + g.teardown
        for child in all {
            collectSchemaProperties(node: child, into: &properties)
        }
    case let .subtest(s):
        for child in s.nodes {
            collectSchemaProperties(node: child, into: &properties)
        }
    case .checkpoint:
        break // checkpoint 不持有 measurement spec
    }
}

// MARK: - Measurement → Schema

private func schemaFor(measurement spec: MeasurementSpec) -> AnyCodableValue {
    var props: [String: AnyCodableValue] = [:]
    var extensionLabels: [AnyCodableValue] = []
    if let unit = spec.unit { props["x-swifthtf-unit"] = .string(unit) }
    if let desc = spec.description { props["description"] = .string(desc) }
    if spec.isOptional { props["x-swifthtf-optional"] = .bool(true) }

    var inferredType: String?

    for v in spec.validators {
        if let r = v as? InRangeValidator {
            applyInRange(r, into: &props)
            inferredType = "number"
        } else if let e = v as? EqualsValueValidator {
            props["const"] = e.expected
        } else if let rx = v as? RegexMeasurementValidator {
            props["pattern"] = .string(rx.pattern)
            inferredType = "string"
        } else if let wp = v as? WithinPercentValidator {
            let tol = abs(wp.target) * (wp.percent / 100.0)
            props["minimum"] = .double(wp.target - tol)
            props["maximum"] = .double(wp.target + tol)
            inferredType = "number"
        } else if let oo = v as? OneOfValidator {
            props["enum"] = .array(oo.allowed)
        } else if let le = v as? LengthEqualsValidator {
            // 同时写 string / array 两套约束，消费方按 type 取（不互冲突）
            let n = Int64(le.expected)
            props["minLength"] = .int(n)
            props["maxLength"] = .int(n)
            props["minItems"] = .int(n)
            props["maxItems"] = .int(n)
        } else {
            // 不映射的 validator：仅留标签
            extensionLabels.append(.string(v.label))
        }
    }
    if let t = inferredType { props["type"] = .string(t) }
    if !extensionLabels.isEmpty {
        props["x-swifthtf-validators"] = .array(extensionLabels)
    }
    return .object(props)
}

private func applyInRange(_ r: InRangeValidator, into props: inout [String: AnyCodableValue]) {
    if r.inclusive {
        if let lo = r.lower { props["minimum"] = .double(lo) }
        if let hi = r.upper { props["maximum"] = .double(hi) }
    } else {
        if let lo = r.lower { props["exclusiveMinimum"] = .double(lo) }
        if let hi = r.upper { props["exclusiveMaximum"] = .double(hi) }
    }
}

// MARK: - Series → Schema

private func schemaFor(series spec: SeriesMeasurementSpec) -> AnyCodableValue {
    var props: [String: AnyCodableValue] = [
        "type": .string("array"),
    ]
    if let desc = spec.description { props["description"] = .string(desc) }
    if spec.isOptional { props["x-swifthtf-optional"] = .bool(true) }

    // 维度 + value 列布局作为扩展字段（标准 JSON Schema 无对应）
    let dimsAsObjects: [AnyCodableValue] = spec.dimensions.map { dim in
        var o: [String: AnyCodableValue] = ["name": .string(dim.name)]
        if let u = dim.unit { o["unit"] = .string(u) }
        return .object(o)
    }
    var seriesMeta: [String: AnyCodableValue] = [
        "dimensions": .array(dimsAsObjects),
    ]
    if let v = spec.value {
        var vo: [String: AnyCodableValue] = ["name": .string(v.name)]
        if let u = v.unit { vo["unit"] = .string(u) }
        seriesMeta["value"] = .object(vo)
    }
    props["x-swifthtf-series"] = .object(seriesMeta)

    var extensionLabels: [AnyCodableValue] = []
    for v in spec.validators {
        if let lv = v as? SeriesLengthValidator {
            if let lo = lv.lower { props["minItems"] = .int(Int64(lo)) }
            if let hi = lv.upper { props["maxItems"] = .int(Int64(hi)) }
        } else {
            extensionLabels.append(.string(v.label))
        }
    }
    if !extensionLabels.isEmpty {
        props["x-swifthtf-validators"] = .array(extensionLabels)
    }
    return .object(props)
}
