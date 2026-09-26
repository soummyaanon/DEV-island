import Foundation
import IslandCore
import Testing

// Ported from 1.x's weather-conditions, weather and location tests.

@Suite struct ConditionTests {
  @Test(arguments: [
    (95, WeatherCondition.thunder), (86, .snow), (81, .rain), (73, .snow), (61, .rain), (45, .fog), (3, .cloudy), (0, .clearDay),
  ])
  func `maps WMO codes by their boundaries`(code: Int, condition: WeatherCondition) {
    #expect(WeatherCondition(wmo: code, isDay: true) == condition)
  }

  @Test func `clear at night is a clear night`() {
    #expect(WeatherCondition(wmo: 1, isDay: false) == .clearNight)
  }

  let now = Date(timeIntervalSince1970: 1_790_000_000)

  @Test func `what's falling wins over golden hour`() {
    #expect(WeatherCondition(code: 95, isDay: true, now: now, sunrise: nil, sunset: now, lastPrecipitation: nil) == .thunder)
  }

  @Test func `a rainbow only just after rain, in daylight`() {
    let rained = now.addingTimeInterval(-20 * 60)
    #expect(WeatherCondition(code: 1, isDay: true, now: now, sunrise: nil, sunset: nil, lastPrecipitation: rained) == .rainbow)
    #expect(WeatherCondition(code: 1, isDay: false, now: now, sunrise: nil, sunset: nil, lastPrecipitation: rained) == .clearNight)
    let long = now.addingTimeInterval(-45 * 60)
    #expect(WeatherCondition(code: 1, isDay: true, now: now, sunrise: nil, sunset: nil, lastPrecipitation: long) == .clearDay)
  }

  @Test func `golden hour replaces clear and cloudy near sunrise and sunset`() {
    #expect(WeatherCondition(code: 3, isDay: true, now: now, sunrise: now.addingTimeInterval(10 * 60), sunset: nil, lastPrecipitation: nil) == .sunrise)
    #expect(WeatherCondition(code: 0, isDay: true, now: now, sunrise: nil, sunset: now.addingTimeInterval(-20 * 60), lastPrecipitation: nil) == .sunset)
    #expect(WeatherCondition(code: 0, isDay: true, now: now, sunrise: nil, sunset: now.addingTimeInterval(-40 * 60), lastPrecipitation: nil) == .clearDay)
  }

  @Test func `formats temperature by the locale's usual unit`() {
    #expect(Temperature.format(celsius: 21.4, units: .auto, region: "IN") == "21°")
    #expect(Temperature.format(celsius: 21.4, units: .auto, region: "US") == "71°")
    #expect(Temperature.format(celsius: 21.4, units: .c, region: "US") == "21°")
    #expect(Temperature.format(celsius: -3.6, units: .f, region: "IN") == "26°")
  }

  @Test func `reads an Open-Meteo reply`() throws {
    let json = #"{"current":{"temperature_2m":18.2,"weather_code":2,"is_day":1},"daily":{"sunrise":[1789990000],"sunset":[1790040000]},"hourly":{"time":[1789992800,1789996400,1790000000],"precipitation":[0.4,0,0]}}"#
    let reply = try JSONDecoder().decode(OpenMeteo.self, from: Data(json.utf8))
    let reading = try #require(reply.reading(now: now))
    #expect(reading.condition == .cloudy)
    #expect(reading.celsius == 18.2)
    #expect(OpenMeteo.lastPrecipitation(times: [1, 2, 3], amounts: [0.1, 0.2, 0], before: Date(timeIntervalSince1970: 2.5)) == Date(timeIntervalSince1970: 2))
  }
}

@Suite struct LocationTests {
  @Test func `reads ISO 6709 in both zone.tab forms, signs included`() throws {
    let kolkata = try #require(Coordinates.parseISO6709("+2232+08822"))
    #expect(abs(kolkata.lat - 22.5333) < 0.001 && abs(kolkata.lon - 88.3667) < 0.001)
    let newYork = try #require(Coordinates.parseISO6709("+404251-0740023"))
    #expect(abs(newYork.lat - 40.7142) < 0.001 && abs(newYork.lon - -74.0064) < 0.001)
    let sydney = try #require(Coordinates.parseISO6709("-3352+15113"))
    #expect(sydney.lat < 0 && sydney.lon > 0)
  }

  @Test(arguments: ["", "2232+08822", "+22+088", "not a coordinate", "+2232+08822extra", "+9932+08822", "+2232+19922"])
  func `rejects malformed or out-of-range coordinates`(value: String) {
    #expect(Coordinates.parseISO6709(value) == nil)
  }

  let table = "# comment\nIN\t+2232+08822\tAsia/Kolkata\nUS\t+404251-0740023\tAmerica/New_York\tEastern (most areas)\nXX\tgarbage\tArea/Broken\n"

  @Test func `finds a zone, tries aliases in order, and never guesses a neighbour`() {
    #expect(Coordinates.fromZoneTable(table, candidates: ["Asia/Calcutta", "Asia/Kolkata"])
      == Coordinates(lat: 22.53, lon: 88.37, source: .timezone, label: "Asia/Kolkata"))
    #expect(Coordinates.fromZoneTable(table, candidates: ["America/New_York"]) != nil)
    #expect(Coordinates.fromZoneTable(table, candidates: ["Mars/Olympus_Mons"]) == nil)
    #expect(Coordinates.fromZoneTable(table, candidates: ["Area/Broken"]) == nil)
    #expect(Coordinates.fromZoneTable("#IN\t+2232+08822\tAsia/Kolkata", candidates: ["Asia/Kolkata"]) == nil)
    #expect(Coordinates.fromZoneTable("", candidates: ["Asia/Kolkata"]) == nil)
  }

  @Test func `rounds to about a kilometre`() {
    #expect(Coordinates.coarsen(22.533333) == 22.53)
    #expect(Coordinates.coarsen(-74.006389) == -74.01)
  }

  @Test func `reads typed coordinates, coarsened, and rejects the rest`() {
    #expect(Coordinates.parseManual("22.57, 88.36")! == (22.57, 88.36))
    #expect(Coordinates.parseManual("-33.87 151.21")! == (-33.87, 151.21))
    #expect(Coordinates.parseManual("22.5678901, 88.3612345")! == (22.57, 88.36))
    for bad in ["Kolkata", "22.57", "", "91, 0", "0, 181"] {
      #expect(Coordinates.parseManual(bad) == nil)
    }
  }

  @Test func `extracts the canonical zone from the localtime link`() {
    #expect(Coordinates.zone(fromLocaltimeLink: "/var/db/timezone/zoneinfo/Asia/Kolkata") == "Asia/Kolkata")
    #expect(Coordinates.zone(fromLocaltimeLink: "/usr/share/zoneinfo/America/Argentina/Buenos_Aires") == "America/Argentina/Buenos_Aires")
    #expect(Coordinates.zone(fromLocaltimeLink: "/usr/share/zoneinfo/posixrules") == nil)
    #expect(Coordinates.zone(fromLocaltimeLink: "") == nil)
  }
}
