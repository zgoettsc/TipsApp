import Foundation
import SwiftUI
import FirebaseDatabase

class AppData: ObservableObject {
    @Published var cycles: [Cycle] = []
    @Published var cycleItems: [UUID: [Item]] = [:]
    @Published var units: [Unit] = []
    @Published var consumptionLog: [UUID: [UUID: [LogEntry]]] = [:]
    @Published var lastResetDate: Date?
    @Published var treatmentTimerEnd: Date? {
        didSet {
            setTreatmentTimerEnd(treatmentTimerEnd)
            DispatchQueue.main.async {
                self.saveCachedData()
                NSLog("treatmentTimerEnd set to: %@, now: %@", String(describing: self.treatmentTimerEnd), String(describing: Date()))
            }
        }
    }
    @Published var users: [User] = []
    @Published var currentUser: User? {
        didSet { saveCurrentUserSettings() }
    }
    @Published var categoryCollapsed: [String: Bool] = [:]
    @Published var roomCode: String? {
        didSet {
            if let roomCode = roomCode {
                UserDefaults.standard.set(roomCode, forKey: "roomCode")
                dbRef = Database.database().reference().child("rooms").child(roomCode)
                loadFromFirebase()
            } else {
                UserDefaults.standard.removeObject(forKey: "roomCode")
                dbRef = nil
            }
        }
    }
    @Published var syncError: String?
    @Published var isLoading: Bool = true
    
    private var dbRef: DatabaseReference?
    private var isAddingCycle = false
    public var treatmentTimerId: String? {
        didSet {
            UserDefaults.standard.set(treatmentTimerId, forKey: "cachedTreatmentTimerId")
            NSLog("Cached treatmentTimerId: %@", String(describing: treatmentTimerId))
        }
    }
    
    private let fileManager = FileManager.default
    private lazy var timerCacheURL: URL = {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("treatmentTimerEnd.cache")
    }()

    init() {
        NSLog("AppData init started at %@", String(describing: Date()))
        if let savedRoomCode = UserDefaults.standard.string(forKey: "roomCode") {
            self.roomCode = savedRoomCode
        }
        units = [Unit(name: "mg"), Unit(name: "g")]
        if let userIdStr = UserDefaults.standard.string(forKey: "currentUserId"),
           let userId = UUID(uuidString: userIdStr) {
            loadCurrentUserSettings(userId: userId)
        }
        loadCachedData()
        rescheduleDailyReminders()
        NSLog("AppData init completed at %@, treatmentTimerEnd: %@", String(describing: Date()), String(describing: treatmentTimerEnd))
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveOnTermination),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func saveOnTermination() {
        NSLog("App terminating, saving state at %@", String(describing: Date()))
        saveCachedData()
    }

    func reloadCachedData() {
        NSLog("reloadCachedData called at %@", String(describing: Date()))
        loadCachedData()
    }

    private func loadCachedData() {
        NSLog("loadCachedData started at %@", String(describing: Date()))
        let now = Date()
        
        // Load other cached data
        if let cycleData = UserDefaults.standard.data(forKey: "cachedCycles"),
           let decodedCycles = try? JSONDecoder().decode([Cycle].self, from: cycleData) {
            self.cycles = decodedCycles
            NSLog("Loaded cached cycles: %ld items", decodedCycles.count)
        }
        if let itemsData = UserDefaults.standard.data(forKey: "cachedCycleItems"),
           let decodedItems = try? JSONDecoder().decode([UUID: [Item]].self, from: itemsData) {
            self.cycleItems = decodedItems
            NSLog("Loaded cached cycleItems: %ld cycles", decodedItems.count)
        }
        if let logData = UserDefaults.standard.data(forKey: "cachedConsumptionLog"),
           let decodedLog = try? JSONDecoder().decode([UUID: [UUID: [LogEntry]]].self, from: logData) {
            self.consumptionLog = decodedLog
            NSLog("Loaded cached consumptionLog: %ld cycles", decodedLog.count)
        }
        
        // Load treatmentTimerEnd from file cache first
        if fileManager.fileExists(atPath: timerCacheURL.path) {
            do {
                let timerData = try Data(contentsOf: timerCacheURL)
                let decodedTimer = try JSONDecoder().decode(Date.self, from: timerData)
                if decodedTimer > now {
                    self.treatmentTimerEnd = decodedTimer
                    NSLog("Loaded treatmentTimerEnd from file cache: %@, now: %@", String(describing: decodedTimer), String(describing: now))
                } else {
                    self.treatmentTimerEnd = nil
                    try? fileManager.removeItem(at: timerCacheURL)
                    NSLog("Discarded expired treatmentTimerEnd from file: %@, now: %@", String(describing: decodedTimer), String(describing: now))
                }
            } catch {
                NSLog("Failed to load treatmentTimerEnd from file cache: %@, path: %@", error.localizedDescription, timerCacheURL.path)
            }
        } else {
            NSLog("No treatmentTimerEnd file cache exists at %@", timerCacheURL.path)
            // Fallback to UserDefaults if file cache fails
            if let timerData = UserDefaults.standard.data(forKey: "cachedTreatmentTimerEnd"),
               let decodedTimer = try? JSONDecoder().decode(Date.self, from: timerData), decodedTimer > now {
                self.treatmentTimerEnd = decodedTimer
                NSLog("Loaded treatmentTimerEnd from UserDefaults: %@, now: %@", String(describing: decodedTimer), String(describing: now))
            } else {
                NSLog("No valid treatmentTimerEnd in UserDefaults or expired")
            }
        }
        
        if let timerId = UserDefaults.standard.string(forKey: "cachedTreatmentTimerId") {
            self.treatmentTimerId = timerId
            NSLog("Loaded cached treatmentTimerId: %@", timerId)
        }
        NSLog("loadCachedData completed at %@, treatmentTimerEnd: %@", String(describing: Date()), String(describing: treatmentTimerEnd))
    }

    private func saveCachedData() {
        NSLog("saveCachedData called at %@", String(describing: Date()))
        if let cycleData = try? JSONEncoder().encode(cycles) {
            UserDefaults.standard.set(cycleData, forKey: "cachedCycles")
        }
        if let itemsData = try? JSONEncoder().encode(cycleItems) {
            UserDefaults.standard.set(itemsData, forKey: "cachedCycleItems")
        }
        if let logData = try? JSONEncoder().encode(consumptionLog) {
            UserDefaults.standard.set(logData, forKey: "cachedConsumptionLog")
        }
        if let timerEnd = treatmentTimerEnd {
            do {
                let timerData = try JSONEncoder().encode(timerEnd)
                try timerData.write(to: timerCacheURL, options: .atomic)
                UserDefaults.standard.set(timerData, forKey: "cachedTreatmentTimerEnd")
                NSLog("Saved treatmentTimerEnd to file and UserDefaults: %@, now: %@", String(describing: timerEnd), String(describing: Date()))
            } catch {
                NSLog("Failed to save treatmentTimerEnd: %@, path: %@", error.localizedDescription, timerCacheURL.path)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: "cachedTreatmentTimerEnd")
            try? fileManager.removeItem(at: timerCacheURL)
            NSLog("Cleared treatmentTimerEnd cache, now: %@", String(describing: Date()))
        }
    }

    func debugState() {
        NSLog("Debug State - treatmentTimerEnd: %@, isLoading: %d, now: %@", String(describing: treatmentTimerEnd), isLoading, String(describing: Date()))
    }

    private func loadCurrentUserSettings(userId: UUID) {
        if let data = UserDefaults.standard.data(forKey: "userSettings_\(userId.uuidString)"),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            self.currentUser = user
            NSLog("Loaded current user %@", userId.uuidString)
        }
    }

    private func saveCurrentUserSettings() {
        guard let user = currentUser else { return }
        UserDefaults.standard.set(user.id.uuidString, forKey: "currentUserId")
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: "userSettings_\(user.id.uuidString)")
        }
        saveCachedData()
    }

    private func loadFromFirebase() {
        guard let dbRef = dbRef else {
            NSLog("No database reference available.")
            syncError = "No room code set."
            self.isLoading = false
            return
        }

        dbRef.child("cycles").observe(.value) { snapshot in
            if self.isAddingCycle { return }
            var newCycles: [Cycle] = []
            var newCycleItems: [UUID: [Item]] = self.cycleItems
            
            NSLog("Firebase snapshot received for cycles: %@", String(describing: snapshot))
            
            if snapshot.value != nil, let value = snapshot.value as? [String: [String: Any]] {
                for (key, dict) in value {
                    var mutableDict = dict
                    mutableDict["id"] = key
                    guard let cycle = Cycle(dictionary: mutableDict) else { continue }
                    newCycles.append(cycle)

                    if let itemsDict = dict["items"] as? [String: [String: Any]], !itemsDict.isEmpty {
                        let firebaseItems = itemsDict.compactMap { (itemKey, itemDict) -> Item? in
                            var mutableItemDict = itemDict
                            mutableItemDict["id"] = itemKey
                            return Item(dictionary: mutableItemDict)
                        }.sorted { $0.order < $1.order }
                        
                        if let localItems = newCycleItems[cycle.id] {
                            var mergedItems = localItems.map { localItem in
                                firebaseItems.first(where: { $0.id == localItem.id }) ?? localItem
                            }
                            let newFirebaseItems = firebaseItems.filter { firebaseItem in
                                !mergedItems.contains(where: { mergedItem in mergedItem.id == firebaseItem.id })
                            }
                            mergedItems.append(contentsOf: newFirebaseItems)
                            newCycleItems[cycle.id] = mergedItems.sorted { $0.order < $1.order }
                        } else {
                            newCycleItems[cycle.id] = firebaseItems
                        }
                        NSLog("Updated items for cycle %@: %@", cycle.id.uuidString, String(describing: newCycleItems[cycle.id]?.map { "\($0.name) - order: \($0.order)" } ?? []))
                    } else if newCycleItems[cycle.id] == nil {
                        newCycleItems[cycle.id] = []
                        NSLog("No items in Firebase for cycle %@: initialized empty", cycle.id.uuidString)
                    }
                }
                DispatchQueue.main.async {
                    self.cycles = newCycles.sorted { $0.startDate < $1.startDate }
                    self.cycleItems = newCycleItems
                    self.saveCachedData()
                    self.syncError = nil
                    NSLog("Synced cycleItems: %@", String(describing: self.cycleItems))
                }
            } else {
                DispatchQueue.main.async {
                    self.cycles = []
                    if self.cycleItems.isEmpty {
                        self.syncError = "No cycles found in Firebase or data is malformed."
                    } else {
                        self.syncError = nil
                    }
                    NSLog("Firebase cycles empty, cycleItems retained: %@", String(describing: self.cycleItems))
                }
            }
        } withCancel: { error in
            DispatchQueue.main.async {
                self.syncError = "Failed to sync cycles: \(error.localizedDescription)"
                self.isLoading = false
                NSLog("Sync error: %@", error.localizedDescription)
            }
        }

        dbRef.child("units").observe(.value) { snapshot in
            if snapshot.value != nil, let value = snapshot.value as? [String: [String: Any]] {
                let units = value.compactMap { (key, dict) -> Unit? in
                    var mutableDict = dict
                    mutableDict["id"] = key
                    return Unit(dictionary: mutableDict)
                }
                DispatchQueue.main.async {
                    self.units = units.isEmpty ? [Unit(name: "mg"), Unit(name: "g")] : units
                }
            }
        }

        dbRef.child("users").observe(.value) { snapshot in
            if snapshot.value != nil, let value = snapshot.value as? [String: [String: Any]] {
                let users = value.compactMap { (key, dict) -> User? in
                    var mutableDict = dict
                    mutableDict["id"] = key
                    return User(dictionary: mutableDict)
                }
                DispatchQueue.main.async {
                    self.users = users
                    if let userIdStr = UserDefaults.standard.string(forKey: "currentUserId"),
                       let userId = UUID(uuidString: userIdStr),
                       let updatedUser = users.first(where: { $0.id == userId }) {
                        self.currentUser = updatedUser
                        self.saveCurrentUserSettings()
                    }
                    self.isLoading = false
                    NSLog("Users synced, treatmentTimerEnd: %@", String(describing: self.treatmentTimerEnd))
                }
            } else {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }

        dbRef.child("consumptionLog").observe(.value) { snapshot in
            if snapshot.value != nil, let value = snapshot.value as? [String: [String: [[String: String]]]] {
                var newLog: [UUID: [UUID: [LogEntry]]] = [:]
                let formatter = ISO8601DateFormatter()
                for (cycleIdStr, itemsLog) in value {
                    guard let cycleId = UUID(uuidString: cycleIdStr) else { continue }
                    var cycleLog: [UUID: [LogEntry]] = [:]
                    for (itemIdStr, entries) in itemsLog {
                        guard let itemId = UUID(uuidString: itemIdStr) else { continue }
                        cycleLog[itemId] = entries.compactMap { entry in
                            guard let timestamp = entry["timestamp"],
                                  let date = formatter.date(from: timestamp),
                                  let userIdStr = entry["userId"],
                                  let userId = UUID(uuidString: userIdStr) else { return nil }
                            return LogEntry(date: date, userId: userId)
                        }
                    }
                    newLog[cycleId] = cycleLog
                }
                DispatchQueue.main.async {
                    self.consumptionLog = newLog
                    self.saveCachedData()
                    NSLog("Consumption log synced: %@", String(describing: self.consumptionLog))
                }
            }
        }

        dbRef.child("categoryCollapsed").observe(.value) { snapshot in
            if snapshot.value != nil, let value = snapshot.value as? [String: Bool] {
                DispatchQueue.main.async {
                    self.categoryCollapsed = value
                }
            }
        }

        dbRef.child("treatmentTimerEnd").observe(.value) { snapshot in
            let formatter = ISO8601DateFormatter()
            DispatchQueue.main.async {
                let now = Date()
                if let timestamp = snapshot.value as? String,
                   let date = formatter.date(from: timestamp), date > now {
                    if self.treatmentTimerEnd != date {
                        self.treatmentTimerEnd = date
                        NSLog("Firebase updated treatmentTimerEnd to: %@, now: %@", String(describing: date), String(describing: now))
                    }
                } else if snapshot.value == nil && self.treatmentTimerEnd != nil && self.treatmentTimerEnd! > now {
                    NSLog("Firebase cleared treatmentTimerEnd, but local timer still active: %@, now: %@", String(describing: self.treatmentTimerEnd), String(describing: now))
                } else {
                    self.treatmentTimerEnd = nil
                    self.treatmentTimerId = nil
                    NSLog("Cleared treatmentTimerEnd from Firebase, now: %@", String(describing: now))
                }
                self.saveCachedData()
            }
        }
    }

    func setLastResetDate(_ date: Date) {
        guard let dbRef = dbRef else { return }
        dbRef.child("lastResetDate").setValue(ISO8601DateFormatter().string(from: date))
        lastResetDate = date
    }

    func setTreatmentTimerEnd(_ date: Date?) {
        guard let dbRef = dbRef else { return }
        let now = Date()
        if let date = date, date > now {
            dbRef.child("treatmentTimerEnd").setValue(ISO8601DateFormatter().string(from: date))
            NSLog("Set treatmentTimerEnd to: %@, now: %@", String(describing: date), String(describing: now))
        } else {
            dbRef.child("treatmentTimerEnd").removeValue()
            self.treatmentTimerId = nil
            NSLog("Cleared treatmentTimerEnd, now: %@", String(describing: now))
        }
        DispatchQueue.main.async {
            self.saveCachedData()
        }
    }

    func addUnit(_ unit: Unit) {
        guard let dbRef = dbRef else { return }
        dbRef.child("units").child(unit.id.uuidString).setValue(unit.toDictionary())
    }

    func addItem(_ item: Item, toCycleId: UUID, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let dbRef = dbRef, cycles.contains(where: { $0.id == toCycleId }), currentUser?.isAdmin == true else {
            completion(false)
            return
        }
        let currentItems = cycleItems[toCycleId] ?? []
        let newOrder = item.order == 0 ? currentItems.count : item.order
        let updatedItem = Item(
            id: item.id,
            name: item.name,
            category: item.category,
            dose: item.dose,
            unit: item.unit,
            weeklyDoses: item.weeklyDoses,
            order: newOrder
        )
        let itemRef = dbRef.child("cycles").child(toCycleId.uuidString).child("items").child(updatedItem.id.uuidString)
        itemRef.setValue(updatedItem.toDictionary()) { error, _ in
            if let error = error {
                NSLog("Error adding item %@ to Firebase: %@", updatedItem.id.uuidString, error.localizedDescription)
                completion(false)
            } else {
                NSLog("Successfully saved item %@ to cycle %@ in Firebase", updatedItem.id.uuidString, toCycleId.uuidString)
                dbRef.child("cycles").child(toCycleId.uuidString).child("items").observeSingleEvent(of: .value) { snapshot in
                    if let itemsDict = snapshot.value as? [String: [String: Any]] {
                        NSLog("Firebase items for %@ after save: %@", toCycleId.uuidString, String(describing: itemsDict))
                    } else {
                        NSLog("Firebase items for %@ empty or missing after save", toCycleId.uuidString)
                    }
                } withCancel: { error in
                    NSLog("Error verifying Firebase items for %@: %@", toCycleId.uuidString, error.localizedDescription)
                }
                
                DispatchQueue.main.async {
                    if var items = self.cycleItems[toCycleId] {
                        if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
                            items[index] = updatedItem
                        } else {
                            items.append(updatedItem)
                        }
                        self.cycleItems[toCycleId] = items.sorted { $0.order < $1.order }
                    } else {
                        self.cycleItems[toCycleId] = [updatedItem]
                    }
                    self.saveCachedData()
                    self.objectWillChange.send()
                    completion(true)
                }
            }
        }
    }

    func saveItems(_ items: [Item], toCycleId: UUID, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let dbRef = dbRef, cycles.contains(where: { $0.id == toCycleId }) else {
            NSLog("Cannot save items: no dbRef or cycle not found")
            completion(false)
            return
        }
        let itemsDict = Dictionary(uniqueKeysWithValues: items.map { ($0.id.uuidString, $0.toDictionary()) })
        dbRef.child("cycles").child(toCycleId.uuidString).child("items").setValue(itemsDict) { error, _ in
            if let error = error {
                NSLog("Error saving items to Firebase: %@", error.localizedDescription)
                completion(false)
            } else {
                NSLog("Successfully saved items to Firebase: %@", String(describing: items.map { "\($0.name) - order: \($0.order)" }))
                DispatchQueue.main.async {
                    self.cycleItems[toCycleId] = items.sorted { $0.order < $1.order }
                    self.saveCachedData()
                    self.objectWillChange.send()
                    completion(true)
                }
            }
        }
    }

    func removeItem(_ itemId: UUID, fromCycleId: UUID) {
        guard let dbRef = dbRef, cycles.contains(where: { $0.id == fromCycleId }), currentUser?.isAdmin == true else { return }
        dbRef.child("cycles").child(fromCycleId.uuidString).child("items").child(itemId.uuidString).removeValue()
        if var items = cycleItems[fromCycleId] {
            items.removeAll { $0.id == itemId }
            cycleItems[fromCycleId] = items
            saveCachedData()
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }

    func addCycle(_ cycle: Cycle, copyItemsFromCycleId: UUID? = nil) {
        guard let dbRef = dbRef, currentUser?.isAdmin == true else { return }
        if cycles.contains(where: { $0.id == cycle.id }) {
            NSLog("Cycle %@ already exists, updating instead", cycle.id.uuidString)
            saveCycleToFirebase(cycle, withItems: cycleItems[cycle.id] ?? [], previousCycleId: copyItemsFromCycleId)
            return
        }
        
        isAddingCycle = true
        cycles.append(cycle)
        var copiedItems: [Item] = []
        
        let effectiveCopyId = copyItemsFromCycleId ?? (cycles.count > 1 ? cycles[cycles.count - 2].id : nil)
        
        if let fromCycleId = effectiveCopyId {
            dbRef.child("cycles").child(fromCycleId.uuidString).child("items").observeSingleEvent(of: .value) { snapshot in
                if let itemsDict = snapshot.value as? [String: [String: Any]] {
                    let itemsToCopy = itemsDict.compactMap { (itemKey, itemDict) -> Item? in
                        var mutableItemDict = itemDict
                        mutableItemDict["id"] = itemKey
                        return Item(dictionary: mutableItemDict)
                    }
                    copiedItems = itemsToCopy.map { item in
                        Item(
                            id: UUID(),
                            name: item.name,
                            category: item.category,
                            dose: item.dose,
                            unit: item.unit,
                            weeklyDoses: item.weeklyDoses,
                            order: item.order
                        )
                    }
                }
                DispatchQueue.main.async {
                    self.cycleItems[cycle.id] = copiedItems
                    self.saveCycleToFirebase(cycle, withItems: copiedItems, previousCycleId: effectiveCopyId)
                }
            } withCancel: { error in
                DispatchQueue.main.async {
                    self.cycleItems[cycle.id] = copiedItems
                    self.saveCycleToFirebase(cycle, withItems: copiedItems, previousCycleId: effectiveCopyId)
                }
            }
        } else {
            cycleItems[cycle.id] = []
            saveCycleToFirebase(cycle, withItems: copiedItems, previousCycleId: effectiveCopyId)
        }
    }

    private func saveCycleToFirebase(_ cycle: Cycle, withItems items: [Item], previousCycleId: UUID?) {
        guard let dbRef = dbRef else { return }
        var cycleDict = cycle.toDictionary()
        let cycleRef = dbRef.child("cycles").child(cycle.id.uuidString)
        
        cycleRef.updateChildValues(cycleDict) { error, _ in
            if let error = error {
                NSLog("Error updating cycle metadata %@: %@", cycle.id.uuidString, error.localizedDescription)
                DispatchQueue.main.async {
                    if let index = self.cycles.firstIndex(where: { $0.id == cycle.id }) {
                        self.cycles.remove(at: index)
                        self.cycleItems.removeValue(forKey: cycle.id)
                    }
                    self.isAddingCycle = false
                    self.objectWillChange.send()
                }
                return
            }
            
            if !items.isEmpty {
                let itemsDict = Dictionary(uniqueKeysWithValues: items.map { ($0.id.uuidString, $0.toDictionary()) })
                cycleRef.child("items").updateChildValues(itemsDict) { error, _ in
                    if let error = error {
                        NSLog("Error adding items to cycle %@: %@", cycle.id.uuidString, error.localizedDescription)
                    }
                }
            }
            
            if let prevId = previousCycleId, let prevItems = self.cycleItems[prevId], !prevItems.isEmpty {
                let prevCycleRef = dbRef.child("cycles").child(prevId.uuidString)
                prevCycleRef.child("items").observeSingleEvent(of: .value) { snapshot in
                    if snapshot.value == nil || (snapshot.value as? [String: [String: Any]])?.isEmpty ?? true {
                        let prevItemsDict = Dictionary(uniqueKeysWithValues: prevItems.map { ($0.id.uuidString, $0.toDictionary()) })
                        prevCycleRef.child("items").updateChildValues(prevItemsDict)
                    }
                }
            }
            
            DispatchQueue.main.async {
                if self.cycleItems[cycle.id] == nil || self.cycleItems[cycle.id]!.isEmpty {
                    self.cycleItems[cycle.id] = items
                }
                self.saveCachedData()
                self.isAddingCycle = false
                self.objectWillChange.send()
            }
        }
    }

    func addUser(_ user: User) {
        guard let dbRef = dbRef else { return }
        let userRef = dbRef.child("users").child(user.id.uuidString)
        userRef.setValue(user.toDictionary()) { error, _ in
            if let error = error {
                NSLog("Error adding/updating user %@: %@", user.id.uuidString, error.localizedDescription)
            } else {
                NSLog("Successfully updated user %@ in Firebase", user.id.uuidString)
            }
        }
        DispatchQueue.main.async {
            if let index = self.users.firstIndex(where: { $0.id == user.id }) {
                self.users[index] = user
            } else {
                self.users.append(user)
            }
            if self.currentUser?.id == user.id {
                self.currentUser = user
            }
            self.saveCurrentUserSettings()
        }
    }

    func logConsumption(itemId: UUID, cycleId: UUID, date: Date = Date()) {
        guard let dbRef = dbRef, let userId = currentUser?.id, cycles.contains(where: { $0.id == cycleId }) else { return }
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: date)
        dbRef.child("consumptionLog").child(cycleId.uuidString).child(itemId.uuidString).observeSingleEvent(of: .value) { snapshot in
            var entries = snapshot.value as? [[String: String]] ?? []
            let newEntry = ["timestamp": timestamp, "userId": userId.uuidString]
            if !entries.contains(where: { $0["timestamp"] == timestamp && $0["userId"] == userId.uuidString }) {
                entries.append(newEntry)
                dbRef.child("consumptionLog").child(cycleId.uuidString).child(itemId.uuidString).setValue(entries)
            }
            DispatchQueue.main.async {
                if var itemLogs = self.consumptionLog[cycleId] {
                    itemLogs[itemId] = entries.compactMap { entry in
                        guard let ts = entry["timestamp"], let date = formatter.date(from: ts),
                              let uid = entry["userId"], let userId = UUID(uuidString: uid) else { return nil }
                        return LogEntry(date: date, userId: userId)
                    }
                    self.consumptionLog[cycleId] = itemLogs
                } else {
                    self.consumptionLog[cycleId] = [itemId: [LogEntry(date: date, userId: userId)]]
                }
                self.saveCachedData()
                self.objectWillChange.send()
            }
        }
    }

    func removeConsumption(itemId: UUID, cycleId: UUID, date: Date) {
        guard let dbRef = dbRef, let userId = currentUser?.id else { return }
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: date)
        
        if var cycleLogs = consumptionLog[cycleId], var itemLogs = cycleLogs[itemId] {
            itemLogs.removeAll { Calendar.current.isDate($0.date, equalTo: date, toGranularity: .second) && $0.userId == userId }
            if itemLogs.isEmpty {
                cycleLogs.removeValue(forKey: itemId)
            } else {
                cycleLogs[itemId] = itemLogs
            }
            consumptionLog[cycleId] = cycleLogs.isEmpty ? nil : cycleLogs
            saveCachedData()
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
        
        dbRef.child("consumptionLog").child(cycleId.uuidString).child(itemId.uuidString).observeSingleEvent(of: .value) { snapshot in
            if var entries = snapshot.value as? [[String: String]] {
                entries.removeAll { $0["timestamp"] == timestamp && $0["userId"] == userId.uuidString }
                dbRef.child("consumptionLog").child(cycleId.uuidString).child(itemId.uuidString).setValue(entries.isEmpty ? nil : entries)
            }
        }
    }

    func setConsumptionLog(itemId: UUID, cycleId: UUID, entries: [LogEntry]) {
        guard let dbRef = dbRef else { return }
        let formatter = ISO8601DateFormatter()
        let entryDicts = entries.map { ["timestamp": formatter.string(from: $0.date), "userId": $0.userId.uuidString] }
        dbRef.child("consumptionLog").child(cycleId.uuidString).child(itemId.uuidString).setValue(entryDicts.isEmpty ? nil : entryDicts)
    }

    func setCategoryCollapsed(_ category: Category, isCollapsed: Bool) {
        guard let dbRef = dbRef else { return }
        categoryCollapsed[category.rawValue] = isCollapsed
        dbRef.child("categoryCollapsed").child(category.rawValue).setValue(isCollapsed)
    }

    func setReminderEnabled(_ category: Category, enabled: Bool) {
        guard var user = currentUser else { return }
        user.remindersEnabled[category] = enabled
        addUser(user)
    }

    func setReminderTime(_ category: Category, time: Date) {
        guard var user = currentUser else {
            NSLog("No current user to set reminder time for %@", category.rawValue)
            return
        }
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: time)
        guard let hour = components.hour, let minute = components.minute else { return }
        let now = Date()
        var normalizedComponents = calendar.dateComponents([.year, .month, .day], from: now)
        normalizedComponents.hour = hour
        normalizedComponents.minute = minute
        normalizedComponents.second = 0
        if let normalizedTime = calendar.date(from: normalizedComponents) {
            user.reminderTimes[category] = normalizedTime
            NSLog("Setting reminder time for %@ to %@", category.rawValue, String(describing: normalizedTime))
            addUser(user)
        } else {
            NSLog("Failed to normalize time for %@", category.rawValue)
        }
    }

    func setTreatmentFoodTimerEnabled(_ enabled: Bool) {
        guard var user = currentUser else { return }
        user.treatmentFoodTimerEnabled = enabled
        addUser(user)
    }

    func setTreatmentTimerDuration(_ duration: TimeInterval) {
        guard var user = currentUser else { return }
        user.treatmentTimerDuration = duration
        addUser(user)
    }

    func resetDaily() {
        let today = Calendar.current.startOfDay(for: Date())
        setLastResetDate(today)
        
        for (cycleId, itemLogs) in consumptionLog {
            var updatedItemLogs = itemLogs
            for (itemId, logs) in itemLogs {
                updatedItemLogs[itemId] = logs.filter { !Calendar.current.isDate($0.date, inSameDayAs: today) }
                if updatedItemLogs[itemId]?.isEmpty ?? false {
                    updatedItemLogs.removeValue(forKey: itemId)
                }
            }
            if let dbRef = dbRef {
                let formatter = ISO8601DateFormatter()
                let updatedLogDict = updatedItemLogs.mapValues { entries in
                    entries.map { ["timestamp": formatter.string(from: $0.date), "userId": $0.userId.uuidString] }
                }
                dbRef.child("consumptionLog").child(cycleId.uuidString).setValue(updatedLogDict.isEmpty ? nil : updatedLogDict)
            }
            consumptionLog[cycleId] = updatedItemLogs.isEmpty ? nil : updatedItemLogs
        }
        
        Category.allCases.forEach { category in
            setCategoryCollapsed(category, isCollapsed: false)
        }
        
        if let endDate = treatmentTimerEnd, endDate > Date() {
            NSLog("Preserving active timer ending at: %@", String(describing: endDate))
        } else {
            treatmentTimerEnd = nil
            treatmentTimerId = nil
            NSLog("Cleared treatmentTimerEnd during reset as it’s past or nil")
        }
        
        saveCachedData()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        NSLog("Reset daily data for %@, preserved historical logs: %@", String(describing: today), String(describing: consumptionLog))
    }

    func checkAndResetIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if lastResetDate == nil || !Calendar.current.isDate(lastResetDate!, inSameDayAs: today) {
            resetDaily()
        } else {
            if let endDate = treatmentTimerEnd, endDate <= Date() {
                treatmentTimerEnd = nil
                treatmentTimerId = nil
                NSLog("Cleared expired treatmentTimerEnd on check: %@, now: %@", String(describing: endDate), String(describing: Date()))
                saveCachedData()
            }
        }
    }

    func currentCycleId() -> UUID? {
        cycles.last?.id
    }

    func verifyFirebaseState() {
        guard let dbRef = dbRef else { return }
        dbRef.child("cycles").observeSingleEvent(of: .value) { snapshot in
            if let value = snapshot.value as? [String: [String: Any]] {
                NSLog("Final Firebase cycles state: %@", String(describing: value))
            } else {
                NSLog("Final Firebase cycles state is empty or missing")
            }
        }
    }

    func rescheduleDailyReminders() {
        guard let user = currentUser else { return }
        for category in Category.allCases where user.remindersEnabled[category] == true {
            if let view = UIApplication.shared.windows.first?.rootViewController?.view {
                RemindersView(appData: self).scheduleReminder(for: category)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 24 * 3600) {
            self.rescheduleDailyReminders()
        }
    }
}
