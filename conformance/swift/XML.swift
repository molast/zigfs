import Foundation

final class ElementCollector: NSObject, XMLParserDelegate {
    private var current: String?
    private var text = ""
    private(set) var values: [String: [String]] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        current = elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if current == elementName {
            values[elementName, default: []].append(text)
            current = nil
            text = ""
        }
    }
}

func parseXML(_ data: Data) throws -> [String: [String]] {
    let collector = ElementCollector()
    let parser = XMLParser(data: data)
    parser.delegate = collector
    guard parser.parse() else {
        throw ConformanceError.invalidResponse("invalid XML response")
    }
    return collector.values
}

func parseXML(_ value: String) throws -> [String: [String]] {
    try parseXML(Data(value.utf8))
}

func xmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
