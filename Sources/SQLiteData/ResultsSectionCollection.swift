import ConcurrencyExtras
import GRDB
import OrderedCollections

/// A collection of query results grouped into sections.
///
/// You do not create this collection directly. Instead, initialize a ``FetchAll`` property with a
/// `sectionBy:` key path and access this collection from the projected value's
/// ``FetchAll/sections`` property:
///
/// ```swift
/// @FetchAll(Reminder.order(by: \.category), sectionBy: \.category)
/// var reminders
///
/// var body: some View {
///   List {
///     ForEach($reminders.sections) { section in
///       Section(section.name) {
///         ForEach(section) { reminder in
///           Text(reminder.title)
///         }
///       }
///     }
///   }
/// }
/// ```
///
/// Results are grouped into a section for each distinct value at the key path. Sections are
/// ordered by the position of their first element in the query's results, and elements within a
/// section follow the query's order. To control the order of sections, order the query by the
/// sectioned column.
public struct ResultsSectionCollection<Element, SectionName: Hashable> {
  let elements: [Element]
  private let sections: OrderedDictionary<SectionName, [Element]>

  init() {
    elements = []
    sections = [:]
  }

  init(elements: some Sequence<Element>, sectionName: (Element) -> SectionName) {
    var allElements: [Element] = []
    var sections: OrderedDictionary<SectionName, [Element]> = [:]
    for element in elements {
      allElements.append(element)
      sections[sectionName(element), default: []].append(element)
    }
    self.elements = allElements
    self.sections = sections
  }

  init(elements: [Element], sectionName: SectionName) {
    self.elements = elements
    self.sections = elements.isEmpty ? [:] : [sectionName: elements]
  }

  init(cursor: QueryCursor<Element>, sectionName: (Element) -> SectionName) throws {
    var elements: [Element] = []
    var sections: OrderedDictionary<SectionName, [Element]> = [:]
    while let element = try cursor.next() {
      elements.append(element)
      sections[sectionName(element), default: []].append(element)
    }
    self.elements = elements
    self.sections = sections
  }

  /// The names of each section in the collection, in the order the sections appear.
  public var sectionNames: [SectionName] {
    Array(sections.keys)
  }

  /// Returns the section with the given name, or `nil` if no such section exists.
  ///
  /// - Parameter name: The name of a section.
  public subscript(sectionName name: SectionName) -> ResultsSection<Element, SectionName>? {
    sections[name].map { ResultsSection(name: name, elements: $0) }
  }

  /// Returns whether or not the collection contains a section with the given name.
  ///
  /// - Parameter name: The name of a section.
  public func contains(sectionName name: SectionName) -> Bool {
    sections.keys.contains(name)
  }

  /// Returns the position of the section with the given name, or `nil` if no such section exists.
  ///
  /// - Parameter name: The name of a section.
  public func index(ofSectionNamed name: SectionName) -> Int? {
    sections.index(forKey: name)
  }
}

extension ResultsSectionCollection: RandomAccessCollection {
  public var startIndex: Int {
    sections.elements.startIndex
  }

  public var endIndex: Int {
    sections.elements.endIndex
  }

  public subscript(position: Int) -> ResultsSection<Element, SectionName> {
    let (name, elements) = sections.elements[position]
    return ResultsSection(name: name, elements: elements)
  }
}

extension ResultsSectionCollection: Sendable where Element: Sendable, SectionName: Sendable {}

extension ResultsSectionCollection: Equatable where Element: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.elementsEqual(rhs)
  }
}

/// A collection of query results in a section, identified by the section's name.
///
/// See ``ResultsSectionCollection`` for more information.
public struct ResultsSection<Element, SectionName: Hashable>: Identifiable {
  /// The name of the section.
  ///
  /// This is the value at the `sectionBy:` key path shared by every element in the section.
  public let name: SectionName

  private let elements: [Element]

  init(name: SectionName, elements: [Element]) {
    self.name = name
    self.elements = elements
  }

  /// The identity of the section, equivalent to its ``name``.
  public var id: SectionName {
    name
  }
}

extension ResultsSection: RandomAccessCollection {
  public var startIndex: Int {
    elements.startIndex
  }

  public var endIndex: Int {
    elements.endIndex
  }

  public subscript(position: Int) -> Element {
    elements[position]
  }
}

extension ResultsSection: Sendable where Element: Sendable, SectionName: Sendable {}

extension ResultsSection: Equatable where Element: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.elements == rhs.elements
  }
}

struct SectionBy<Element>: Hashable, Sendable {
  let keyPath: AnyHashableSendable
  let name: @Sendable (Element) -> String

  init(_ keyPath: KeyPath<Element, String>) {
    let keyPath = unsafeBitCast(keyPath, to: (any KeyPath<Element, String> & Sendable).self)
    self.keyPath = AnyHashableSendable(keyPath)
    self.name = { $0[keyPath: keyPath] }
  }

  init(_ keyPath: KeyPath<Element, String?>) {
    let keyPath = unsafeBitCast(keyPath, to: (any KeyPath<Element, String?> & Sendable).self)
    self.keyPath = AnyHashableSendable(keyPath)
    self.name = { $0[keyPath: keyPath] ?? "" }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.keyPath == rhs.keyPath
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(keyPath)
  }
}
