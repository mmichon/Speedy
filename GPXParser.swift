import Foundation
import CoreLocation

class GPXParser: NSObject, XMLParserDelegate {
    private var locations: [CLLocation] = []
    private var currentElement: String = ""
    private var currentLatitude: Double = 0.0
    private var currentLongitude: Double = 0.0

    func parse(data: Data) -> [CLLocation] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return locations
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if currentElement == "trkpt" {
            if let latString = attributeDict["lat"], let lonString = attributeDict["lon"], let lat = Double(latString), let lon = Double(lonString) {
                currentLatitude = lat
                currentLongitude = lon
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "trkpt" {
            locations.append(CLLocation(latitude: currentLatitude, longitude: currentLongitude))
        }
    }
}
