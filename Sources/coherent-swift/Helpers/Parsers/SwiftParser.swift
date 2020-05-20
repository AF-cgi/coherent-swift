//
//  coherent-swift
//
//  Created by Arthur Alves on 08/05/2020.
//

import Foundation
import PathKit
import SwiftCLI

typealias ParsedItem = (item: String, range: NSRange, type: String)

public class SwiftParser {
    let logger = Logger.shared
    static let shared = SwiftParser()
    
    func parseFile(filename: String, in path: Path, onSucces: (([ReportDefinition]) -> Void)? = nil) {
        let fileManager = FileManager.default
        let filePath = Path("\(path)/\(filename)")
        let fileData = fileManager.contents(atPath: filePath.absolute().description)
        
        guard
            let data = fileData,
            let stringData = String(data: data, encoding: .utf8),
            !stringData.isEmpty
        else { return }
        
        let cleanContent = excludeComments(stringContent: stringData)
        let classes = parseDefinition(stringContent: cleanContent)
        classes.forEach {
            logger.logDebug("Definition: ", item: $0.name, indentationLevel: 1, color: .cyan)
            $0.properties.forEach { (property) in
                logger.logDebug("Property: ", item: property.name, indentationLevel: 2, color: .cyan)
            }
            $0.methods.forEach { (method) in
                logger.logDebug("Method: ", item: method.name, indentationLevel: 2, color: .cyan)
                
                method.properties.forEach { (property) in
                    logger.logDebug("Property: ", item: property.name, indentationLevel: 3, color: .cyan)
                }
                
                logger.logDebug("Cohesion: ", item: method.cohesion+"%%", indentationLevel: 3, color: .cyan)
            }
            logger.logDebug("Cohesion: ", item: $0.cohesion+"%%", indentationLevel: 2, color: .cyan)
        }
        
        onSucces?(classes)
    }
    
    func method(_ method: ReportMethod, containsProperty property: ReportProperty, numberOfOccasions: Int = 1) -> Bool {
        let range = NSRange(location: 0, length: method.contentString.utf16.count)
        guard let regex = try? NSRegularExpression(pattern: property.name) else { return false }
        let matches = regex.matches(in: method.contentString, range: range)
        return matches.count >= numberOfOccasions
    }
    
    // MARK: - Private methods
    
    private func excludeComments(stringContent: String) -> String {
        let range = NSRange(location: 0, length: stringContent.utf16.count)
        let pattern = "(/\\*(.|\n)*?\\*/|//(.*?)\r?\n|@(\"[^\"]*\")+)"
        guard let regex = try? NSRegularExpression(pattern: pattern)
        else {
            logger.logError("Couldn't create NSRegularExpression to exclude comments from file content: ", item: pattern)
            return stringContent
        }
        var cleanContent = stringContent
        let matches = regex.matches(in: stringContent, range: range)
        matches.forEach { match in
            if let range = Range(match.range, in: stringContent) {
                let methodSubstring = String(stringContent[range])
                cleanContent = cleanContent.replacingOccurrences(of: methodSubstring, with: "")
            }
        }
        
        return cleanContent
    }
    
    private func parseDefinition(stringContent: String) -> [ReportDefinition] {
        var definitions: [ReportDefinition] = []
    
        let parseType: ParseType = .definition
        
        let rawDefinitions = parseSwift(stringContent: stringContent, type: parseType)
        if rawDefinitions.isEmpty { return [] }
        
        for iterator in 0...rawDefinitions.count-1 {
            let definitionName = rawDefinitions[iterator].item
            
            var definition: ReportDefinition = ReportDefinition(name: definitionName)
            
            let delimiter = iterator+1 > rawDefinitions.count-1 ? "\\}" : "(\(parseType.regex())) \(rawDefinitions[iterator+1].item)"
            let regexPattern = "(?s)(?<=\(definitionName)).*(?=\(delimiter))"

            if let range = stringContent.range(of: regexPattern, options: .regularExpression) {
                let definitionContent = String(stringContent[range])
                
                definition.properties = parseSwiftProperties(stringContent: definitionContent)
                definition.methods = parseSwiftMethod(stringContent: definitionContent, withinDefinition: definition)
                
                var cohesion: Double = 0
                if !definition.methods.isEmpty {
                    cohesion = Cohesion.main.generateCohesion(for: definition)
                    
                } else {
                    /*
                     * if a definition doesn't contain properties nor methods, its
                     * still considered to have high cohesion
                     */
                    cohesion = 100
                }
                definition.cohesion = cohesion.formattedCohesion()
            }
            definitions.append(definition)
        }
        
        return definitions
    }
    
    private func parseSwiftProperties(stringContent: String) -> [ReportProperty] {
        var properties: [ReportProperty] = []
        let rawProperties = parseSwift(stringContent: stringContent, type: .property)
        properties = rawProperties.map { ReportProperty(name: $0.item, propertyType: PropertyType(rawValue: $0.type) ?? .instanceProperty) }
        return properties
    }
    
    private func parseSwiftMethod(stringContent: String, withinDefinition definition: ReportDefinition) -> [ReportMethod] {
        var methods: [ReportMethod] = []
        let rawMethods = parseSwift(stringContent: stringContent, type: .method)
        
        if rawMethods.isEmpty { return [] }
        
        for iterator in 0...rawMethods.count-1 {
            let methodName = rawMethods[iterator].item
            let processedForRegex = processedMethodName(methodName)
            
            var method: ReportMethod = ReportMethod(name: methodName)
            let delimiter = iterator+1 > rawMethods.count-1 ? "\\}" : "\(ParseType.method.regex())"
            let regexPattern = "(?s)(?<=\(processedForRegex)).*(\(delimiter))"
            
            if let range = stringContent.range(of: regexPattern, options: .regularExpression) {
                let methodContent = String(stringContent[range])
                method.contentString = methodContent
                method.properties = parseSwiftProperties(stringContent: methodContent)
                
                let methodCohesion = Cohesion.main.generateCohesion(for: method, withinDefinition: definition)
                method.cohesion = methodCohesion.formattedCohesion()
            }
            methods.append(method)
        }
        return methods
    }
    
    private func parseSwift(stringContent: String, type: ParseType) -> [ParsedItem] {
        
        let range = NSRange(location: 0, length: stringContent.utf16.count)
        let pattern = "(?<=\(type.regex()) )(.*)(\(type.delimiter()))"
        guard let regex = try? NSRegularExpression(pattern: pattern)
        else {
            logger.logError("Couldn't create NSRegularExpression with: ", item: pattern)
            return []
        }
        var parsedItems: [ParsedItem] = []
        
        switch type {
        case .property:
            propertyLineParsing(stringContent: stringContent).forEach {
                parsedItems.append($0)
            }
        default:
            let matches = regex.matches(in: stringContent, range: range)
            processParsedItems(with: matches, in: stringContent, type: type).forEach {
                parsedItems.append($0)
            }
        }
        return parsedItems
    }
    
    private func propertyLineParsing(stringContent: String) -> [ParsedItem] {
        var parsedItems: [ParsedItem] = []
        let type = ParseType.property
        let pattern = "(?<=\(type.regex()) )(.*)(\(type.delimiter()))"
        guard let regex = try? NSRegularExpression(pattern: pattern)
        else {
            logger.logError("Couldn't create NSRegularExpression with: ", item: pattern)
            return parsedItems
        }
        
        var dictionaryContent: [String] = []
        
        stringContent.enumerateLines { (line, _) in
            dictionaryContent.append(line)
        }
        
        let methodType = ParseType.method
        let methodPattern = "(?<=\(methodType.regex()) )(.*)(\(methodType.delimiter()))"
        guard let methodRegex = try? NSRegularExpression(pattern: methodPattern)
        else {
            logger.logError("Couldn't create NSRegularExpression with: ", item: methodPattern)
            return parsedItems
        }
        
        for lineCount in 0...dictionaryContent.count-1 {
            let lineContent = dictionaryContent[lineCount]
            let range = NSRange(location: 0, length: lineContent.utf16.count)

            let methodMatches = methodRegex.matches(in: lineContent, range: range)
            if !methodMatches.isEmpty { break }
            
            let matches = regex.matches(in: lineContent, range: range)
            
            processParsedItems(with: matches, in: lineContent, type: .property).forEach {
                parsedItems.append($0)
            }
        }
        
        return parsedItems
    }
    
    private func processParsedItems(with regexMatches: [NSTextCheckingResult], in contentString: String, type: ParseType) -> [ParsedItem] {
        var parsedItems: [ParsedItem] = []
        
        regexMatches.forEach { match in
            
            if let range = Range(match.range, in: contentString) {
                var finalType = ""
                switch type {
                case .method:
                    guard
                        let methodSubstring = String(contentString[range]).split(separator: "{").first
                        else { return }
                    let finalString = String(methodSubstring).trimmingCharacters(in: [" "])
                    parsedItems.append((item: finalString, range: match.range, type: type.rawValue))
                    
                case .property:
                    finalType = PropertyType.instanceProperty.rawValue
                    if contentString.contains(PropertyType.classProperty.rawValue) {
                        finalType = PropertyType.classProperty.rawValue
                    }
                    
                    var propertiesInLine: [String] = []
                    if contentString.contains("let (") || contentString.contains("var (") {
                        propertiesInLine = processTuple(in: String(contentString[range]))
                    } else if let processedPropertyName = processPropertyName(in: String(contentString[range])) {
                        propertiesInLine.append(processedPropertyName)
                    }
                    
                    propertiesInLine.forEach { property in
                        parsedItems.append((item: property, range: match.range, type: finalType))
                    }
                    
                default:
                    finalType = type.rawValue
                    guard
                        let substringNoColons = String(contentString[range]).split(separator: ":").first,
                        let finalString = String(substringNoColons).split(separator: " ").first
                    else { return }
                    parsedItems.append((item: String(finalString), range: match.range, type: finalType))
                }
            }
        }
        return parsedItems
    }
    
    private func processedMethodName(_ name: String) -> String {
        guard let cleanSubstring = name.split(separator: "(").first
        else { return name }
        return String(cleanSubstring)
    }
    
    private func processTuple(in contentString: String) -> [String] {
        let cleanString = contentString
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "=", with: "")
        guard
            let substringNoColons = cleanString.split(separator: ":").first
        else { return [] }
        
        let allStrings = String(substringNoColons).split(separator: ",")
        return allStrings.map { String($0) }
    }
    
    private func processPropertyName(in contentString: String) -> String? {
        let cleanString = contentString
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "")
        
        guard
            let substringNoColons = cleanString.split(separator: ":").first,
            let substringNoClosure = String(substringNoColons).split(separator: "=").first,
            let finalString = String(substringNoClosure).split(separator: " ").first
        else { return nil }
        return String(finalString)
    }
}
