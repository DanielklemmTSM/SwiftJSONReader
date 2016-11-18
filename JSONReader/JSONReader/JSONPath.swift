//
//  JSONReader.swift
//  JSONReader
//
//  Created by Benedict Cohen on 28/11/2015.
//  Copyright © 2015 Benedict Cohen. All rights reserved.
//

import Foundation


/**
JSONPath represents a path through a tree of JSON objects.

TODO: Write a grammer of a path

*/
public struct JSONPath {

    public enum Component {
        case text(String)
        case numeric(Int64)
        case selfReference
    }

    public let components: [Component]


    //MARK: Instance life cycle

    public init(components: [Component]) {
        self.components = components
    }
}


//MARK:- Equatable

extension JSONPath: Equatable {

}


public func ==(lhs: JSONPath, rhs: JSONPath) -> Bool {
    return lhs.components == rhs.components
}


extension JSONPath.Component: Equatable {

    fileprivate func asTuple()-> (text: String?, number: Int64?, isSelfReference: Bool) {
        switch self {
        case .text(let text):
            return (text, nil, false)
        case .numeric(let number):
            return (nil, number, false)
        case .selfReference:
            return (nil, nil, true)
        }
    }
}


public func ==(lhs: JSONPath.Component, rhs: JSONPath.Component) -> Bool {

    let lhsValues = lhs.asTuple()
    let rhsValues = rhs.asTuple()

    return lhsValues.text == rhsValues.text &&
           lhsValues.number == rhsValues.number &&
           lhsValues.isSelfReference == rhsValues.isSelfReference
}


//MARK:- Debug Description

extension JSONPath: CustomDebugStringConvertible {

    public var debugDescription: String {
        var description = ""

        for component in components {
            switch component {
            case .text(let text):
                description += "['\(text)']"
                break

            case .numeric(let number):
                description += "[\(number)]"

            case .selfReference:
                description += "[self]"
            }
        }

        return description
    }
}


extension JSONPath.Component: CustomDebugStringConvertible {

    public var debugDescription: String {
        switch self {
        case .numeric(let i):
            return "[\(i)]"
        case .selfReference:
            return "[self]"
        case .text(let text):
            return encodeStringAsSubscriptRepresentation(text)
        }
    }

    fileprivate func encodeStringAsSubscriptRepresentation(_ text: String) -> String {
        let mutableText =  NSMutableString(string: text)
        //Note that the order of the replacements is significant. We must replace '`' first otherwise our replacements will get replaced.
        mutableText.replaceOccurrences(of: "`", with: "``", options: [], range: NSRange(location: 0, length: mutableText.length))
        mutableText.replaceOccurrences(of: "'", with: "`'", options: [], range: NSRange(location: 0, length: mutableText.length))

        return "['\(mutableText)']"
    }
}


extension JSONPath {
    @available(*, deprecated: 0.5, message: "Use JSONPath.Component.debugDescription instead.")
    public static func encodeTextAsSubscriptPathComponent(_ text: String) -> String {
        return JSONPath.Component.text(text).debugDescription
    }
}


//MARK:- Path parsing

extension JSONPath {

    public enum ParsingError: Error {
        //TODO: Add details to these errors (location, expect input etc)
        case expectedComponent
        case invalidSubscriptValue
        case expectedEndOfSubscript
        case unexpectedEndOfString
    }


    fileprivate static func componentsInPath(_ path: String) throws -> [Component] {
        var components = [Component]()
        try JSONPath.enumerateComponentsInPath(path) { component, componentIdx, stop in
            components.append(component)
        }
        return components
    }


    public static func enumerateComponentsInPath(_ JSONPath: String, enumerator: (_ component: Component, _ componentIdx: Int, _ stop: inout Bool) throws -> Void) throws {

        let scanner = Scanner(string: JSONPath)
        scanner.charactersToBeSkipped = nil //Don't skip whitespace!

        var componentIdx = 0
        repeat {

            let component = try scanComponent(scanner)
            //Call the enumerator
            var stop = false
            try enumerator(component, componentIdx, &stop)
            if stop { return }

            //Prepare for next loop
            componentIdx += 1

        } while !scanner.isAtEnd

        //Done without error
    }


    fileprivate static func scanComponent(_ scanner: Scanner) throws -> Component {

        if let component = try scanSubscriptComponent(scanner) {
            return component
        }

        if let component = try scanIdentifierComponent(scanner) {
            return component
        }

        throw ParsingError.expectedComponent
    }


    fileprivate static func scanSubscriptComponent(_ scanner: Scanner) throws -> Component? {
        let result: Component

        //Is it subscript?
        let isSubscript = scanner.scanString("[", into: nil)
        guard isSubscript else {
            return nil
        }

        //Scan the value
        var idx: Int64 = 0
        var text: String = ""
        switch scanner {

        case (_) where scanner.scanInt64(&idx):
            result = .numeric(idx)

        case (_) where scanner.scanString("self", into: nil):
            result = .selfReference

        case (_) where try scanSingleQuoteDelimittedString(scanner, string: &text):
            result = .text(text)

        default:
            throw ParsingError.invalidSubscriptValue
        }

        //Close the subscript
        guard scanner.scanString("]", into: nil) else {
            throw ParsingError.expectedEndOfSubscript
        }

        consumeOptionalTraillingDot(scanner)

        return result
    }


    fileprivate static let headCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ$_")
    fileprivate static let bodyCharacters: CharacterSet = {
        let mutableCharacterSet = NSMutableCharacterSet(charactersIn: "0123456789")
        mutableCharacterSet.formUnion(with: headCharacters)
        return mutableCharacterSet as CharacterSet
        }()

    fileprivate static func scanIdentifierComponent(_ scanner: Scanner) throws -> Component? {
        //Technically there are a lot more unicode code points that are acceptable, but we go for 99+% of JSON keys.
        //See on https://mathiasbynens.be/notes/javascript-properties.

        var identifier = ""
        var headFragment: NSString?
        guard scanner.scanCharacters(from: headCharacters, into: &headFragment) else {
            return nil
        }
        identifier.append(headFragment as! String)

        var bodyFragment: NSString?
        if scanner.scanCharacters(from: bodyCharacters, into: &bodyFragment) {
            identifier.append(bodyFragment as! String)
        }

        consumeOptionalTraillingDot(scanner)

        return .text(identifier)
    }

    fileprivate static let dotCharacterSet = CharacterSet(charactersIn: ".")

    fileprivate static func consumeOptionalTraillingDot(_ scanner: Scanner) {
        scanner.scanCharacters(from: dotCharacterSet, into: nil)
    }


    fileprivate static let subScriptDelimiters = CharacterSet(charactersIn: "`'")

    fileprivate static func scanSingleQuoteDelimittedString(_ scanner: Scanner, string: inout String) throws -> Bool {

        guard scanner.scanString("'", into: nil) else {
            return false
        }

        var text = ""
        mainLoop: while !scanner.isAtEnd {
            //Scan normal text
            var fragment: NSString?
            let didScanFragment = scanner.scanUpToCharacters(from: subScriptDelimiters, into:&fragment)
            if didScanFragment,
                let fragment = fragment as? String {
                    text.append(fragment)
            }

            //Scan escape sequences
            escapeSequenceLoop: while true {
                if scanner.scanString("`'", into: nil) {
                    text.append("'")
                } else if scanner.scanString("``", into: nil) {
                    text.append("`")
                } else if scanner.scanString("`", into: nil) {
                    text.append("`") //This is technically an invalid escape sequence but we're forgiving.
                } else {
                    break escapeSequenceLoop
                }
            }

            //Attempt to scan the closing delimiter
            if scanner.scanString("'", into: nil) {
                //Done!
                string = text
                return true
            }
        }

        throw JSONPath.ParsingError.unexpectedEndOfString
    }
}


//MARK:- Initialization from string

extension JSONPath {

    /// A cache of the values of each component of a path. The key is the path and the value is an array of NSNumber, NSString and NSNull which represent .Numeric, .Text and .SelfReference respectively.
    fileprivate static let componentsCache = NSCache<AnyObject, AnyObject>()


    fileprivate static func componentsForStringRepresentation(_ string: String) -> [Component]? {
        guard let foundationComponents = JSONPath.componentsCache.object(forKey: string as AnyObject) as? [AnyObject] else {
            return nil
        }
        let components = foundationComponents.map({ object -> Component in
            //The cache can't store enums so we have to map back from AnyObject
            switch object {
            case is NSNumber:
                return Component.numeric(object.int64Value)

            case is NSString:
                return Component.text(object as! String)

            case is NSNull:
                return Component.selfReference

            default:
                fatalError("Unexpected type in component cache.")
            }
        })
        return components
    }


    fileprivate static func setComponents(_ components: [Component], forStringRepresentation string: String) {
        //We can't store an array of enums in an NSCache so we map to an array of AnyObject.
        let FoundationComponents = components.map({ component -> AnyObject in
            switch component {
            case .numeric(let number):
                return NSNumber(value: number as Int64)

            case .text(let text):
                return NSString(string: text)

            case .selfReference:
                return NSNull()
            }
        })
        JSONPath.componentsCache.setObject(FoundationComponents as AnyObject, forKey: string as AnyObject)
    }


    public init(path: String) throws {
        let components: [Component]

        if let cachedComponents = JSONPath.componentsForStringRepresentation(path) {
            components = cachedComponents
        } else {
            components = try JSONPath.componentsInPath(path)
            JSONPath.setComponents(components, forStringRepresentation: path)
        }

        self.init(components: components)
    }
}


//MARK:- StringLiteralConvertible

extension JSONPath: ExpressibleByStringLiteral {

    public init(stringLiteral path: StringLiteralType) {
        do {
            try self.init(path: path)
        } catch let error {
            fatalError("String literal does not represent a valid JSONPath. Error: \(error)")
        }
    }


    public typealias ExtendedGraphemeClusterLiteralType = StringLiteralType

    public init(extendedGraphemeClusterLiteral path: ExtendedGraphemeClusterLiteralType) {
        do {
            try self.init(path: path)
        } catch let error {
            fatalError("String literal does not represent a valid JSONPath. Error: \(error)")
        }
    }


    public typealias UnicodeScalarLiteralType = String

    public init(unicodeScalarLiteral path: UnicodeScalarLiteralType) {
        do {
            try self.init(path: "\(path)")
        } catch let error {
            fatalError("String literal does not represent a valid JSONPath. Error: \(error)")
        }
    }
}
