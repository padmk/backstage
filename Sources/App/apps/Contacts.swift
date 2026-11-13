// Contacts through the Contacts framework, which reaches the data directly and touches no app.

import Contacts

private let accessRequestSeconds = 170
// One request at a time uses the shared store.
private let sharedStore = Exclusive(CNContactStore())

private var summaryKeys: [CNKeyDescriptor] {
  [
    CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
    CNContactOrganizationNameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
    CNContactPhoneNumbersKey as CNKeyDescriptor,
  ]
}
private var detailKeys: [CNKeyDescriptor] {
  summaryKeys + [
    CNContactJobTitleKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey, CNContactBirthdayKey,
    CNContactDatesKey, CNContactNicknameKey,
  ].map { $0 as CNKeyDescriptor }
}

// Only the user's choice in Backstage asks (requestContactsAccess); an operation that finds no answer yet fails
// with what to do.
private func withContacts<T>(_ work: (_ store: CNContactStore) throws -> T) throws -> T {
  try sharedStore.withLock { store in
    try currentConnection()?.throwIfCancelled()
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized: break
    case .notDetermined: throw grantMissing("Contacts")
    // Limited access shows only the contacts the user picked, so it is refused rather than giving partial answers.
    default: throw contactsDenied()
    }
    return try work(store)
  }
}

private func contactsDenied() -> HelperError {
  HelperError(code: "access_denied", message: "macOS does not let Backstage use Contacts. Allow full access in System Settings > Privacy & Security > Contacts > Backstage, then try again.")
}

private func labeled<Value>(_ values: [CNLabeledValue<Value>], _ text: (Value) -> String) -> [JSON] {
  values.map { item in
    var entry: JSON = ["value": text(item.value)]
    if let label = item.label { entry["label"] = CNLabeledValue<Value>.localizedString(forLabel: label) }
    return entry
  }
}

private func summary(_ contact: CNContact) -> JSON {
  var result: JSON = [
    "id": contact.identifier, "name": CNContactFormatter.string(from: contact, style: .fullName) ?? "",
    "emails": labeled(contact.emailAddresses) { $0 as String }, "phones": labeled(contact.phoneNumbers) { $0.stringValue },
  ]
  if !contact.organizationName.isEmpty { result["organization"] = contact.organizationName }
  return result
}

private func details(_ contact: CNContact) -> JSON {
  var result = summary(contact)
  if !contact.jobTitle.isEmpty { result["job_title"] = contact.jobTitle }
  if !contact.nickname.isEmpty { result["nickname"] = contact.nickname }
  // Without a year, as Contacts allows, the birthday is MM-DD.
  if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
    result["birthday"] = (birthday.year.map { String(format: "%04d-", $0) } ?? "") + String(format: "%02d-%02d", month, day)
  }
  result["addresses"] = labeled(contact.postalAddresses) { CNPostalAddressFormatter.string(from: $0, style: .mailingAddress) }
  result["urls"] = labeled(contact.urlAddresses) { $0 as String }
  return result
}

private let search = Operation(
  name: "search", summary: "Find contacts by name, email address or phone number", effect: .reads,
  arguments: [
    Argument(name: "query", kind: .string, required: true, description: "The start of a name or of a word in it, a whole email address, or a whole phone number"),
    limitArgument,
  ]
) { arguments in
  let query = try string(arguments, "query").trimmingCharacters(in: .whitespaces)
  guard !query.isEmpty else { throw HelperError(code: "invalid_arguments", message: "query is empty.") }
  return try withContacts { store in
    let predicate = ContactHandle(query)?.predicate ?? CNContact.predicateForContacts(matchingName: query)
    let found = try store.unifiedContacts(matching: predicate, keysToFetch: summaryKeys)
    return ["total": found.count, "contacts": found.prefix(limit(arguments)).map(summary)] as JSON
  }
}

private let read = Operation(
  name: "read", summary: "Read a contact's details", effect: .reads,
  arguments: [Argument(name: "id", kind: .string, required: true, description: "Contact id from search")]
) { arguments in
  let id = try string(arguments, "id")
  return try withContacts { store in
    guard let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: detailKeys) else {
      throw HelperError(code: "not_found", message: "There is no contact with id \(id).")
    }
    return details(contact)
  }
}

private let add = Operation(
  name: "add", summary: "Add a contact", effect: .changes,
  arguments: [
    Argument(name: "given_name", kind: .string, required: false, description: "First name"),
    Argument(name: "family_name", kind: .string, required: false, description: "Last name"),
    Argument(name: "organization", kind: .string, required: false, description: "Company"),
    Argument(name: "email", kind: .string, required: false, description: "Email address"),
    Argument(name: "phone", kind: .string, required: false, description: "Phone number"),
  ]
) { arguments in
  let contact = CNMutableContact()
  contact.givenName = optionalString(arguments, "given_name") ?? ""
  contact.familyName = optionalString(arguments, "family_name") ?? ""
  contact.organizationName = optionalString(arguments, "organization") ?? ""
  guard !(contact.givenName + contact.familyName + contact.organizationName).isEmpty else {
    throw HelperError(code: "invalid_arguments", message: "Give a name or an organization.")
  }
  if let email = optionalString(arguments, "email") { contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)] }
  if let phone = optionalString(arguments, "phone") { contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))] }
  return try withContacts { store in
    let request = CNSaveRequest()
    request.add(contact, toContainerWithIdentifier: nil)
    try store.execute(request)
    guard let saved = try? CNContactStore().unifiedContact(withIdentifier: contact.identifier, keysToFetch: detailKeys) else {
      throw HelperError(code: "outcome_unknown", message: "Contacts saved the contact but it cannot be read back. Search before trying again.")
    }
    var result = details(saved)
    result["verified"] = saved.givenName == contact.givenName && saved.familyName == contact.familyName
      && saved.organizationName == contact.organizationName
      && saved.emailAddresses.map { $0.value as String } == contact.emailAddresses.map { $0.value as String }
      && saved.phoneNumbers.map(\.value.stringValue) == contact.phoneNumbers.map(\.value.stringValue)
    return result
  }
}

let contactsKnowledge = AppKnowledge(
  bundleId: "com.apple.AddressBook", name: "Contacts", summary: "Find, read and add contacts",
  access: "Read and add contacts in every account, even while Contacts is closed",
  pitfalls: ["A person linked across accounts appears once, with the details of every linked card."],
  operations: [search, read, add])

// MARK: Names for other apps' handles

// A phone number or email address as messaging apps store a person's handle. Anything else, such as a business
// sender's name ("Orange") or a group's id, is no handle.
enum ContactHandle: Hashable {
  // Digits, with a leading + when the handle has one.
  case phone(String)
  // Lowercased.
  case email(String)

  init?(_ handle: String) {
    let trimmed = handle.trimmingCharacters(in: .whitespaces)
    if trimmed.contains("@") {
      guard !trimmed.contains(where: \.isWhitespace) else { return nil }
      self = .email(trimmed.lowercased())
    } else if trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || "+-(). ".contains($0)) }), trimmed.contains(where: \.isNumber),
      !trimmed.dropFirst().contains("+")
    {
      self = .phone((trimmed.hasPrefix("+") ? "+" : "") + trimmed.filter(\.isNumber))
    } else {
      return nil
    }
  }

  // Contacts compares phone numbers itself, so one stored without the country code still matches.
  var predicate: NSPredicate {
    switch self {
    case .phone(let number): CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
    case .email(let address): CNContact.predicateForContacts(matchingEmailAddress: address)
    }
  }
}

// The person a handle belongs to: the contact's id, which tells apart two people of the same name, and its name.
struct HandleContact: Equatable {
  let id: String
  let name: String
}

typealias ContactLookup = (ContactHandle) -> HandleContact?

// The phone and email keys are part of it because Contacts refuses a phone or email predicate without them.
private var nameKeys: [CNKeyDescriptor] {
  [
    CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor,
    CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
  ]
}

// Looks handles up in Contacts, each once, when Contacts is on the user's list and macOS allows it; nil otherwise. It
// never asks macOS for access, so it shows no prompt. Each request makes its own, so the names are as current as the
// request and follow the list.
func contactLookup() -> ContactLookup? {
  guard CNContactStore.authorizationStatus(for: .contacts) == .authorized,
    let contacts = try? installedIdentity(installedApp(contactsKnowledge.bundleId)), ApprovalGate.access(contacts) == .allowed
  else { return nil }
  var known: [ContactHandle: HandleContact?] = [:]
  return { handle in
    if let found = known[handle] { return found }
    let contact = sharedStore.withLock { (try? $0.unifiedContacts(matching: handle.predicate, keysToFetch: nameKeys))?.first }
    let name = contact.map { CNContactFormatter.string(from: $0, style: .fullName) ?? $0.organizationName } ?? ""
    let found = contact.flatMap { name.isEmpty ? nil : HandleContact(id: $0.identifier, name: name) }
    known[handle] = found
    return found
  }
}

// MARK: Access, for the App Access list

func contactsAccessState() -> GrantState {
  switch CNContactStore.authorizationStatus(for: .contacts) {
  case .authorized: .granted
  case .notDetermined: .notAsked
  default: .denied
  }
}

// Shows macOS's prompt when it has not asked yet.
// The wait for the user's answer holds no lock, so operations do not queue behind the prompt.
func requestContactsAccess() {
  guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
  let answered = DispatchSemaphore(value: 0)
  CNContactStore().requestAccess(for: .contacts) { _, _ in answered.signal() }
  _ = answered.wait(timeout: .now() + .seconds(accessRequestSeconds))
}
