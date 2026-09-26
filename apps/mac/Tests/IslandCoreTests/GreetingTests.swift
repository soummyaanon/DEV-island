import Foundation
import IslandCore
import Testing

// Ported from 1.x's greeting tests.

@Suite struct GreetingTests {
  private func at(_ hour: Int) -> Date {
    var components = DateComponents()
    (components.year, components.month, components.day, components.hour) = (2026, 9, 26, hour)
    return Calendar.current.date(from: components)!
  }

  @Test func `names the part of the day`() {
    #expect(Greeting.partOfDay(7) == .morning)
    #expect(Greeting.partOfDay(13) == .afternoon)
    #expect(Greeting.partOfDay(19) == .evening)
    #expect(Greeting.partOfDay(2) == .night)
  }

  @Test func `titles launch and welcome-back`() {
    #expect(Greeting.title(.init(name: "Sam", date: at(8), occasion: .launch)) == "Good morning, Sam")
    #expect(Greeting.title(.init(name: "", date: at(23), occasion: .launch)) == "Hey there")
    #expect(Greeting.title(.init(name: "Sam", date: at(15), occasion: .welcomeBack)) == "Welcome back, Sam")
  }

  @Test func `hands the model short fact lines, skipping what's unknown`() {
    let text = Greeting.factsText(.init(name: "Sam", date: at(8), battery: (80, true), occasion: .launch))
    #expect(text.contains("Name: Sam"))
    #expect(text.contains("Battery: 80%, charging"))
    #expect(!text.contains("Weather"))
  }

  @Test func `falls back to a local line, low battery first`() {
    let facts = Greeting.Facts(name: "Sam", date: at(8), battery: (9, false), occasion: .launch)
    #expect(Greeting.fallbackLine(facts, pick: 0).contains("9%"))
    #expect(!Greeting.fallbackLine(facts, pick: 0.99).isEmpty)
  }

  @Test func `keeps the line to one tidy sentence`() {
    #expect(Greeting.tidy(" \"Hello\n there\" ") == "Hello there")
    #expect(Greeting.tidy(String(repeating: "word ", count: 60)).count <= 141)
  }

  @Test func `drops the model's own hello and the name the title already shows`() {
    #expect(Greeting.dropSalutation("Good night, Soumyaranjan. Ready for your Saturday adventure?", name: "Soumyaranjan") == "Ready for your Saturday adventure?")
    #expect(Greeting.dropSalutation("Hey soumyaranjan, coffee first?", name: "Soumyaranjan") == "Coffee first?")
    #expect(Greeting.dropSalutation("Ready when you are.", name: "Sam") == "Ready when you are.")
    #expect(Greeting.dropSalutation("Hello!", name: "Sam") == "Hello!")
    #expect(Greeting.dropSalutation("Hey there, Sam! Big day?", name: "Sam") == "Big day?")
  }

  @Test func `finds a first name from the full name, else the login`() {
    #expect(Greeting.firstName(fullName: "sam lee", login: "x") == "Sam")
    #expect(Greeting.firstName(fullName: "", login: "jane.doe42") == "Jane")
  }

  @Test func `stays up long enough to read, capped`() {
    #expect(Greeting.duration(for: "") == 4.2)
    #expect(Greeting.duration(for: String(repeating: "x", count: 500)) == 12)
  }
}
