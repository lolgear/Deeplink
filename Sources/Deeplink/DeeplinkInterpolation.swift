//
//  DeeplinkInterpolation.swift
//  
//
//  Created by Tiziano Coroneo on 21/02/2020.
//

import Foundation

public struct DeeplinkInterpolation<Value>: Equatable, Hashable, StringInterpolationProtocol {

    // MARK: - Deeplink Component

    /// A ``Deeplink/DeeplinkInterpolation`` is made out of a list of components.
    /// A `Component` can be or a literal string or an argument (keypath).
    ///
    /// For example, the deeplink `/sell/ticket/\(\.id)` has two components:
    /// a literal string `.literal("/sell/ticket/")`, and a argument `.argument(\.id)`.
    /// The deeplink `/sell/\(.ticket)/regular` has three components:
    /// a literal string `.literal("/sell/")`, an argument `.argument(\.ticket)` and a final `.literal("/regular")`.
    enum Component: Equatable, Hashable, CustomStringConvertible {
        case literal(String)
        case argument(WritableKeyPath<Value, String?>)
        case argumentList(WritableKeyPath<Value, [String]?>, separator: Character)

        // MARK: - Methods

        /// The string contained in this component, in case it is a `literal` component. `nil` otherwise.
        var literalPath: String? {
            guard case .literal(let path) = self
                else { return nil }
            return path
        }

        /// The keypath contained in this component, in case it is an `argument` component. `nil` otherwise.
        var argumentPath: WritableKeyPath<Value, String?>? {
            guard case .argument(let path) = self
                else { return nil }
            return path
        }

        /// The keypath contained in this component, in case it is an `argumentList` component. `nil` otherwise.
        var argumentListPath: WritableKeyPath<Value, [String]?>? {
            guard case .argumentList(let path, _) = self
            else { return nil }
            return path
        }

        /// The separator character contained in this component, in case it is an `argumentList` component. `nil` otherwise.
        /// The separator is used to tell apart each item in the argument list.
        var argumentListSeparator: Character? {
            guard case .argumentList(_, let separator) = self
            else { return nil }
            return separator
        }

        /// `true` if this component contains an argument keypath.
        var isArgument: Bool {
            switch self {
            case .literal: return false
            case .argument, .argumentList: return true
            }
        }

        var description: String {
            switch self {
            case .literal(let value): return value
            case .argument: return "{{ argument }}"
            case .argumentList: return "{{ argument list }}"
            }
        }
    }

    // MARK: - Properties

    /// List of components that make up the deeplink interpolation.
    private(set) var components: [Component]

    // MARK: - Initializers

    /// Initialize with a list of components. Used only in unit tests, and to initialize a ``Deeplink/DeeplinkInterpolation`` from a literal string (see ``Deeplink/Deeplink``).
    init(
        components: [Component]
    ) {
        self.components = components
    }

    /// Initializer used by Swift when creating a ``Deeplink/DeeplinkInterpolation`` from a string interpolation.
    /// The arguments should be used for performance tuning, but we cannot use them because of how the components are stored in a list.
    public init(
        literalCapacity: Int,
        interpolationCount: Int
    ) {
        self.components = []
    }

    // MARK: - StringInterpolationProtocol implementation

    /// Method called by Swift when the string interpolation contains a string literal.
    ///
    /// Example: the deeplink `"/sell/ticket/\(\.id)"` will trigger the following calls in order:
    /// ```swift
    /// var interpolation = DeeplinkInterpolation(literalCapacity: 13, interpolationCount: 1)
    /// interpolation.appendLiteral("/sell/ticket/")
    /// interpolation.appendInterpolation(\.id)
    /// ```
    public mutating func appendLiteral(
        _ literal: String
    ) {
        guard !literal.isEmpty else { return }

        self.components.append(.literal(literal))
    }

    /// Method called by Swift when the string interpolation contains an interpolation argument.
    ///
    /// Example: the deeplink `"/sell/ticket/\(\.id)"` will trigger the following calls in order:
    /// ```swift
    /// var interpolation = DeeplinkInterpolation(literalCapacity: 13, interpolationCount: 1)
    /// interpolation.appendLiteral("/sell/ticket/")
    /// interpolation.appendInterpolation(\.id)
    /// ```
    public mutating func appendInterpolation(
        _ path: WritableKeyPath<Value, String?>
    ) throws {
        let newComponent: Component = .argument(path)

        // Check if we have two consecutive argument components, if so throw
        if let last = self.components.last,
            case .argument(let lastPath) = last {
            throw DeeplinkError.cannotSetTwoArgumentsConsecutively(
                argument1: lastPath,
                argument2: path)
        }

        if let last = self.components.last,
           case .argumentList(let lastPath, _) = last {
            throw DeeplinkError.cannotSetTwoArgumentsConsecutively(
                argument1: lastPath,
                argument2: path)
        }

        // Check if we already have a component with the specified keypath, if so throw
        if self.components.contains(newComponent) {
            throw DeeplinkError.argumentRepeated(argument: path)
        }

        self.components.append(newComponent)
    }

    /// Method called by Swift when the string interpolation contains an interpolation argument list.
    ///
    /// Example: the deeplink `"/sell/ticket/ids=\(\.idList, separator: ",")"` will trigger the following calls in order:
    /// ```swift
    /// var interpolation = DeeplinkInterpolation(literalCapacity: 17, interpolationCount: 1)
    /// interpolation.appendLiteral("/sell/ticket/ids=")
    /// interpolation.appendInterpolation(\.idList, separator: ",")
    /// ```
    public mutating func appendInterpolation(
        _ path: WritableKeyPath<Value, [String]?>,
        separator: Character
    ) throws {
        let newComponent: Component = .argumentList(path, separator: separator)

        // Check if we have two consecutive argument components, if so throw
        if let last = self.components.last,
           case .argument(let lastPath) = last {
            throw DeeplinkError.cannotSetTwoArgumentsConsecutively(
                argument1: lastPath,
                argument2: path)
        }

        if let last = self.components.last,
           case .argumentList(let lastPath, _) = last {
            throw DeeplinkError.cannotSetTwoArgumentsConsecutively(
                argument1: lastPath,
                argument2: path)
        }

        // Check if we already have a component with the specified keypath, if so throw
        if self.components.contains(where: {
            $0.argumentListPath == newComponent.argumentListPath
        }) {
            throw DeeplinkError.argumentRepeated(argument: path)
        }

        self.components.append(newComponent)
    }


    // MARK: - Methods

    /// Attempt to match a `URL` using the current interpolation template. It will throw an error if the pattern does not match the `URL`; otherwise, it will assign the part of string that correspond to each interpolation argument to the corresponding property on the `instance` object.
    /// - Parameters:
    ///   - url: `URL` to parse. Needs to conform to `RFC 3986`.
    ///   - instance: The object to which the argument values will be assigned.
    ///
    /// - Throws: a `DeeplinkError` if we cannot parse relative path, query items or fragments from the URL, or if there is no valid match.
    func parse(
        _ url: URL,
        into instance: inout Value
    ) throws {
        // Attempt to get information on the url. Throw if it doesn't conform to `RFC 3986`.
        let data = try URLPatternMatcher(url: url)

        // Use the url data to pattern match the deeplink components.
        try data.match(components: self.components, into: &instance)
    }
}

// MARK: - CustomStringConvertible

extension DeeplinkInterpolation: CustomStringConvertible {
    public var description: String {
        components
            .map { $0.description }
            .joined()
    }
}
