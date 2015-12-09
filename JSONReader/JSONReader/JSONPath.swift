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
*/
public struct JSONPath {

    public enum Component {
        case Text(String)
        case Numeric(Int64)
        case SelfReference
    }


    public let components: [Component]


    //MARK:- Instance life cycle

    public init(components: [Component]) {
        self.components = components
    }
}


//MARK: Path parsing

extension JSONPath {

    public enum ParsingError: ErrorType {
        //TODO: Add details to these errors (location, expect input etc)
        case ExpectedComponent
        case InvalidSubscriptValue
        case ExpectedEndOfSubscript
        case UnexpectedEndOfString
    }


    private static let subScriptDelimiters = NSCharacterSet(charactersInString: "`'")
    private static let headCharacters = NSCharacterSet(charactersInString: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ$_")
    private static let bodyCharacters: NSCharacterSet = {
        let mutableCharacterSet = NSMutableCharacterSet(charactersInString: "0123456789")
        mutableCharacterSet.formUnionWithCharacterSet(headCharacters)
        return mutableCharacterSet
        }()


    private static func componentsInPath(path: String) throws -> [Component] {
        var components = [Component]()
        try JSONPath.enumerateComponentsInPath(path) { component, componentIdx, stop in
            components.append(component)
        }
        return components
    }


    public static func enumerateComponentsInPath(JSONPath: String, enumerator: (component: Component, componentIdx: Int, inout stop: Bool) throws -> Void) throws {

        let scanner = NSScanner(string: JSONPath)
        scanner.charactersToBeSkipped = nil //Don't skip whitespace!

        var componentIdx = 0
        repeat {

            let component = try scanComponent(scanner)
            //Call the enumerator
            var stop = false
            try enumerator(component: component, componentIdx: componentIdx, stop: &stop)
            if stop { return }

            //Prepare for next loop
            componentIdx++

        } while !scanner.atEnd

        //Done without error
    }


    private static func scanComponent(scanner: NSScanner) throws -> Component {

        if let component = try scanSubscriptComponent(scanner) {
            return component
        }

        if let component = try scanIdentifierComponent(scanner) {
            return component
        }

        throw ParsingError.ExpectedComponent
    }


    private static func scanSubscriptComponent(scanner: NSScanner) throws -> Component? {
        let result: Component

        //Is it subscript?
        let isSubscript = scanner.scanString("[", intoString: nil)
        guard isSubscript else {
            return nil
        }

        //Scan the value
        var idx: Int64 = 0
        var text: String = ""
        switch scanner {

        case (_) where scanner.scanLongLong(&idx):
            result = .Numeric(idx)

        case (_) where scanner.scanString("self", intoString: nil):
            result = .SelfReference

        case (_) where try scanner.scanSingleQuoteDelimittedString(&text):
            result = .Text(text)

        default:
            throw ParsingError.InvalidSubscriptValue
        }

        //Close the subscript
        guard scanner.scanString("]", intoString: nil) else {
            throw ParsingError.ExpectedEndOfSubscript
        }

        scanner.consumeOptionalTraillingDot()

        return result
    }


    private static func scanIdentifierComponent(scanner: NSScanner) throws -> Component? {
        //Technically there are a lot more unicode code points that are acceptable, but we go for 99+% of JSON keys.
        //See on https://mathiasbynens.be/notes/javascript-properties.

        var identifier = ""
        var headFragment: NSString?
        guard scanner.scanCharactersFromSet(headCharacters, intoString: &headFragment) else {
            return nil
        }
        identifier.appendContentsOf(headFragment as! String)

        var bodyFragment: NSString?
        if scanner.scanCharactersFromSet(bodyCharacters, intoString: &bodyFragment) {
            identifier.appendContentsOf(bodyFragment as! String)
        }

        scanner.consumeOptionalTraillingDot()

        return .Text(identifier)
    }


    /**
    <#Description#>

    - parameter text: <#text description#>

    - returns: <#return value description#>
    */
    static func encodeTextAsSubscriptPathComponent(text: String) -> String {
        let mutableText =  NSMutableString(string: text)
        //Note that the order of the replacements is significant. We must replace '`' first otherwise our replacements will get replaced.
        mutableText.replaceOccurrencesOfString("`", withString: "``", options: [], range: NSRange(location: 0, length: mutableText.length))
        mutableText.replaceOccurrencesOfString("'", withString: "`'", options: [], range: NSRange(location: 0, length: mutableText.length))

        return "['\(mutableText)']"
    }

    /// A cache of the values of each component of a path. The key is the path and the value is an array of NSNumber, NSString and NSNull which represent .Numeric, .Text and .SelfReference respectively.
    private static let componentsCache = NSCache()


    public init(path: String) throws {
        let components: [Component]

        if let cachedComponents = JSONPath.componentsCache.objectForKey(path) as? [AnyObject] {
            //The cache can't store enums so we have to map back from AnyObject
            components = cachedComponents.map({ object -> Component in
                switch object {
                case is NSNumber:
                    return Component.Numeric(object.longLongValue)

                case is NSString:
                    return Component.Text(object as! String)

                case is NSNull:
                    return Component.SelfReference

                default:
                    fatalError("Unexpected type in component cache.")
                }
            })
        } else {
            components = try JSONPath.componentsInPath(path)

            //We can't store an array of enums in an NSCache so we map to an array of AnyObject.
            let componentsArray = components.map({ component -> AnyObject in
                switch component {
                case .Numeric(let number):
                    return NSNumber(longLong: number)

                case .Text(let text):
                    return NSString(string: text)

                case .SelfReference:
                    return NSNull()
                }
            })
            JSONPath.componentsCache.setObject(componentsArray, forKey: path)
        }
        
        self.init(components: components)
    }

}


//MARK:- StringLiteralConvertible

extension JSONPath: StringLiteralConvertible {

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


//MARK:- Description

extension JSONPath: CustomDebugStringConvertible {

    public var debugDescription: String {
        var description = ""

        for component in components {
            switch component {
            case .Text(let text):
                description += "['\(text)']"
                break

            case .Numeric(let number):
                description += "[\(number)]"

            case .SelfReference:
                description += "[self]"
            }
        }

        return description
    }
}


//MARK: NSScanner parsing extension

extension NSScanner {


    private static let dotCharacterSet = NSCharacterSet(charactersInString: ".")

    private func consumeOptionalTraillingDot() {
        scanCharactersFromSet(NSScanner.dotCharacterSet, intoString: nil)
    }


    private static let singleQuoteDelimittedStringDelimiters = NSCharacterSet(charactersInString:"`'")

    private func scanSingleQuoteDelimittedString(inout string: String) throws -> Bool {

        guard scanString("'", intoString: nil) else {
            return false
        }

        var text = ""
        mainLoop: while !atEnd {
            //Scan normal text
            var fragment: NSString?
            let didScanFragment = scanUpToCharactersFromSet(NSScanner.singleQuoteDelimittedStringDelimiters, intoString:&fragment)
            if didScanFragment,
                let fragment = fragment as? String {
                    text.appendContentsOf(fragment)
            }

            //Scan escape sequences
            escapeSequenceLoop: while true {
                if scanString("`'", intoString: nil) {
                    text.appendContentsOf("'")
                } else
                    if scanString("``", intoString: nil) {
                        text.appendContentsOf("`")
                    } else
                        if scanString("`", intoString: nil) {
                            text.appendContentsOf("`") //This is technically an invalid escape sequence but we're forgiving.
                        } else {
                            break escapeSequenceLoop
                }
            }

            //Attempt to scan the closing delimiter
            if scanString("'", intoString: nil) {
                //Done!
                string = text
                return true
            }
        }
        
        throw JSONPath.ParsingError.UnexpectedEndOfString
    }
}