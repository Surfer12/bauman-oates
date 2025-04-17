// MARK: - Core Data Models

/// Represents the possible states of an emergency sequence
enum EmergencyState: String, Codable {
    case inactive    = "INACTIVE"    // No emergency in progress
    case pending     = "PENDING"     // Countdown initiated
    case active      = "ACTIVE"      // Emergency services contacted
    case cancelled   = "CANCELLED"   // Explicitly cancelled by user
    case recovering  = "RECOVERING"  // Post-emergency recovery mode
}

/// Encapsulates the complete model of an emergency event
struct EmergencyContext: Codable, Identifiable {
    let id: Int64?
    let userId: Int64
    let deviceId: String
    var state: EmergencyState
    var initiationTime: Date?
    var activationTime: Date?
    var lastLocationUpdate: Date?
    var currentLatitude: Double?
    var currentLongitude: Double?
    var activationMethod: String?
    var contactsNotified: Bool
    var recoveryAttempts: Int
    var emergencyType: String?
    var deviceOrigin: String
    
    var isActive: Bool {
        return state == .pending || state == .active || state == .recovering
    }
}

// MARK: - Emergency Manager Implementation

/// Central coordinator for emergency operations across iOS and watchOS
class EmergencySOSManager: NSObject, ObservableObject {
    // Singleton instance for app-wide access
    static let shared = EmergencySOSManager()
    
    // MARK: - Published State
    
    /// Reactive state properties for SwiftUI integration
    @Published private(set) var currentState: EmergencyState = .inactive
    @Published private(set) var activeContext: EmergencyContext?
    @Published private(set) var countdownRemaining: Int = 0
    @Published private(set) var isProcessingRequest: Bool = false
    @Published private(set) var lastError: Error?
    
    // MARK: - Dependencies
    
    private let locationManager = LocationManager()
    private let notificationManager = NotificationManager()
    private let apiClient = EmergencyAPIClient()
    private var watchConnectivityManager: WatchConnectivityManager?
    
    // Timer properties for countdown and recovery
    private var countdownTimer: Timer?
    private var recoveryTimer: Timer?
    private let countdownDuration = 3 // seconds
    
    // Alert sound players
    private var alertSoundPlayer: AVAudioPlayer?
    private var hapticGenerator: UINotificationFeedbackGenerator?
    
    private override init() {
        super.init()
        
        // Initialize watch connectivity if available
        if WCSession.isSupported() {
            watchConnectivityManager = WatchConnectivityManager(delegate: self)
        }
        
        // Set up location manager
        locationManager.delegate = self
        
        // Initialize haptic generator
        hapticGenerator = UINotificationFeedbackGenerator()
        hapticGenerator?.prepare()
        
        // Load and configure alert sounds
        configureAudioSession()
        loadAlertSounds()
        
        // Check for existing emergency context in persistent storage
        recoverFromPersistentState()
    }
    
    // MARK: - Public API
    
    /// Initiates the emergency sequence
    func initiateEmergency(type: String = "SAFETY", method: String = "BUTTON_HOLD") {
        // Block duplicate initiations
        guard currentState == .inactive else { return }
        
        // Update state and begin countdown
        currentState = .pending
        
        // Begin countdown with audio-visual feedback
        startCountdown()
        
        // Prepare location services
        locationManager.requestLocationPermission()
        locationManager.startUpdatingLocation()
        
        // Create pending emergency on server asynchronously
        createEmergencyContext(type: type, method: method)
    }
    
    /// Cancels emergency during countdown
    func cancelCountdown() {
        // Only allow cancellation during the pending state
        guard currentState == .pending else { return }
        
        // Stop countdown and alert feedback
        stopCountdown()
        
        // Reset state
        if let context = activeContext {
            // If server-side context was created, cancel it remotely
            cancelEmergencyContext(contextId: context.id ?? 0)
        } else {
            // If no server context yet, just reset locally
            resetState()
        }
        
        // Provide haptic feedback for cancellation
        hapticGenerator?.notificationOccurred(.success)
    }
    
    /// Activates emergency immediately (bypasses countdown)
    func activateEmergencyImmediately(type: String = "SAFETY", method: String = "SOS_BUTTON") {
        // Initialize directly in active state
        currentState = .active
        
        // Skip countdown, create context and activate immediately
        createEmergencyContext(type: type, method: method) { [weak self] success in
            if success, let context = self?.activeContext {
                self?.activateEmergencyContext(contextId: context.id ?? 0)
            }
        }
        
        // Start location tracking and notifications
        locationManager.requestLocationPermission()
        locationManager.startUpdatingHighAccuracyLocation()
        
        // Generate urgent haptic alert
        hapticGenerator?.notificationOccurred(.error)
        
        // Play critical alert sound (if configured)
        playCriticalAlert()
    }
    
    /// Activates emergency after countdown finishes
    func completeCountdownAndActivate() {
        guard currentState == .pending, let context = activeContext else { return }
        
        // Update state
        currentState = .active
        
        // Stop countdown feedback
        stopCountdown()
        
        // Activate emergency on server
        activateEmergencyContext(contextId: context.id ?? 0)
        
        // Switch to high-accuracy location
        locationManager.startUpdatingHighAccuracyLocation()
        
        // Generate haptic alert
        hapticGenerator?.notificationOccurred(.error)
    }
    
    /// Begins recovery process after emergency services have been contacted
    func beginRecovery() {
        guard currentState == .active, let context = activeContext else { return }
        
        // Update local state
        currentState = .recovering
        
        // Start recovery on server
        apiClient.beginRecovery(contextId: context.id ?? 0) { [weak self] result in
            switch result {
            case .success(let updatedContext):
                self?.activeContext = updatedContext
                self?.persistEmergencyState()
                
                // Start recovery timeout timer (30 minutes)
                self?.startRecoveryTimer()
                
            case .failure(let error):
                self?.lastError = error
                // Still try to maintain recovery state locally even if server call fails
            }
        }
        
        // Sync state with companion device
        synchronizeStateWithCompanionDevice()
    }
    
    /// Completes recovery and returns to normal state
    func completeRecovery() {
        guard (currentState == .active || currentState == .recovering), 
              let context = activeContext else { return }
        
        // Call server to complete recovery
        apiClient.completeRecovery(contextId: context.id ?? 0) { [weak self] result in
            switch result {
            case .success(_):
                self?.resetState()
                
            case .failure(let error):
                self?.lastError = error
                // Still reset state locally even if server call fails
                self?.resetState()
            }
        }
        
        // Cancel any timers and reset location updates
        stopRecoveryTimer()
        locationManager.stopUpdatingLocation()
        
        // Sync with companion device
        synchronizeStateWithCompanionDevice()
        
        // Provide completion feedback
        hapticGenerator?.notificationOccurred(.success)
    }
    
    // MARK: - Private Implementation Methods
    
    private func startCountdown() {
        countdownRemaining = countdownDuration
        
        // Start countdown timer
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { 
                timer.invalidate()
                return 
            }
            
            self.countdownRemaining -= 1
            
            // Generate appropriate feedback based on remaining time
            if self.countdownRemaining > 0 {
                // Play countdown sound and haptic
                self.playCountdownSound(secondsRemaining: self.countdownRemaining)
                self.hapticGenerator?.notificationOccurred(.warning)
            } else {
                // Time's up - activate emergency
                timer.invalidate()
                self.completeCountdownAndActivate()
            }
        }
        
        // Start immediately
        countdownTimer?.fire()
    }
    
    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        stopAlertSounds()
    }
    
    private func startRecoveryTimer() {
        // 30-minute timeout for recovery mode
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: false) { [weak self] _ in
            // Auto-complete recovery after timeout
            self?.completeRecovery()
        }
    }
    
    private func stopRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }
    
    private func resetState() {
        currentState = .inactive
        activeContext = nil
        countdownRemaining = 0
        lastError = nil
        
        // Clear from persistent storage
        clearPersistedEmergencyState()
        
        // Notify observers of state change
        NotificationCenter.default.post(name: .emergencyStateChanged, object: nil)
    }
    
    // MARK: - API Communication
    
    private func createEmergencyContext(type: String, method: String, completion: ((Bool) -> Void)? = nil) {
        guard let userId = UserManager.shared.currentUserId,
              let deviceId = UIDevice.current.identifierForVendor?.uuidString else {
            lastError = EmergencyError.missingUserInformation
            completion?(false)
            return
        }
        
        // Determine device origin
        #if os(watchOS)
        let deviceOrigin = "WATCH"
        #else
        let deviceOrigin = "PHONE"
        #endif
        
        isProcessingRequest = true
        
        // Create context on server
        apiClient.createEmergencyContext(
            userId: userId,
            deviceId: deviceId,
            deviceOrigin: deviceOrigin,
            emergencyType: type,
            activationMethod: method
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.isProcessingRequest = false
                
                switch result {
                case .success(let context):
                    self?.activeContext = context
                    self?.persistEmergencyState()
                    self?.synchronizeStateWithCompanionDevice()
                    completion?(true)
                    
                case .failure(let error):
                    self?.lastError = error
                    completion?(false)
                }
            }
        }
    }
    
    private func activateEmergencyContext(contextId: Int64) {
        guard let location = locationManager.lastLocation else {
            // Activate without location if unavailable
            activateWithoutLocation(contextId: contextId)
            return
        }
        
        isProcessingRequest = true
        
        // Activate on server with current location
        apiClient.activateEmergency(
            contextId: contextId,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.isProcessingRequest = false
                
                switch result {
                case .success(let updatedContext):
                    self?.activeContext = updatedContext
                    self?.persistEmergencyState()
                    self?.synchronizeStateWithCompanionDevice()
                    
                case .failure(let error):
                    self?.lastError = error
                    // Still maintain active state locally even if server call fails
                }
            }
        }
    }
    
    private func activateWithoutLocation(contextId: Int64) {
        isProcessingRequest = true
        
        // Activate on server without location data
        apiClient.activateEmergency(contextId: contextId) { [weak self] result in
            DispatchQueue.main.async {
                self?.isProcessingRequest = false
                
                switch result {
                case .success(let updatedContext):
                    self?.activeContext = updatedContext
                    self?.persistEmergencyState()
                    self?.synchronizeStateWithCompanionDevice()
                    
                case .failure(let error):
                    self?.lastError = error
                    // Still maintain active state locally even if server call fails
                }
            }
        }
    }
    
    private func cancelEmergencyContext(contextId: Int64) {
        isProcessingRequest = true
        
        apiClient.cancelEmergency(contextId: contextId) { [weak self] result in
            DispatchQueue.main.async {
                self?.isProcessingRequest = false
                
                switch result {
                case .success(_):
                    self?.resetState()
                    
                case .failure(let error):
                    self?.lastError = error
                    // Still reset state locally even if server call fails
                    self?.resetState()
                }
            }
        }
    }
    
    // MARK: - Location Updates
    
    /// Sends updated location to the server during an active emergency
    private func updateLocationOnServer(location: CLLocation) {
        guard currentState == .active || currentState == .recovering,
              let context = activeContext else { return }
        
        apiClient.updateLocation(
            contextId: context.id ?? 0,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        ) { [weak self] result in
            if case .success(let updated) = result {
                self?.activeContext = updated
            }
        }
    }
    
    // MARK: - State Persistence
    
    private func persistEmergencyState() {
        guard let context = activeContext else { return }
        
        // Encode emergency context to JSON
        guard let encodedData = try? JSONEncoder().encode(context) else { return }
        
        // Store in UserDefaults (or more secure storage in production)
        UserDefaults.standard.set(encodedData, forKey: "activeEmergencyContext")
        UserDefaults.standard.set(currentState.rawValue, forKey: "emergencyState")
    }
    
    private func recoverFromPersistentState() {
        // Attempt to restore state from persistent storage
        if let stateString = UserDefaults.standard.string(forKey: "emergencyState"),
           let state = EmergencyState(rawValue: stateString),
           let contextData = UserDefaults.standard.data(forKey: "activeEmergencyContext"),
           let context = try? JSONDecoder().decode(EmergencyContext.self, from: contextData) {
            
            // Restore the state
            currentState = state
            activeContext = context
            
            // If we're still in an active state, reconnect with server
            if state == .active || state == .recovering {
                // Verify context is still active on server
                verifyEmergencyContextWithServer(contextId: context.id ?? 0)
            }
        }
    }
    
    private func clearPersistedEmergencyState() {
        UserDefaults.standard.removeObject(forKey: "activeEmergencyContext")
        UserDefaults.standard.removeObject(forKey: "emergencyState")
    }
    
    private func verifyEmergencyContextWithServer(contextId: Int64) {
        apiClient.getEmergencyContext(contextId: contextId) { [weak self] result in
            switch result {
            case .success(let serverContext):
                // Update local state to match server
                self?.activeContext = serverContext
                self?.currentState = serverContext.state
                
                // Restart appropriate systems based on state
                if serverContext.state == .active || serverContext.state == .recovering {
                    self?.locationManager.startUpdatingLocation()
                    
                    if serverContext.state == .recovering {
                        self?.startRecoveryTimer()
                    }
                } else {
                    // If server shows inactive/cancelled, reset local state
                    self?.resetState()
                }
                
            case .failure(_):
                // On error, maintain local state but try to reconnect later
                self?.scheduleServerReconnection()
            }
        }
    }
    
    private func scheduleServerReconnection() {
        // Attempt to reconnect after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, let context = self.activeContext else { return }
            self.verifyEmergencyContextWithServer(contextId: context.id ?? 0)
        }
    }
    
    // MARK: - Audio and Haptic Feedback
    
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    private func loadAlertSounds() {
        // Load alert sounds from bundle
        // Implementation details omitted for brevity
    }
    
    private func playCountdownSound(secondsRemaining: Int) {
        // Play appropriate sound for countdown
        // Implementation details omitted for brevity
    }
    
    private func playCriticalAlert() {
        // Play urgent alert sound
        // Implementation details omitted for brevity
    }
    
    private func stopAlertSounds() {
        alertSoundPlayer?.stop()
    }
    
    // MARK: - Watch Connectivity
    
    private func synchronizeStateWithCompanionDevice() {
        // Send current state to companion device (phone-to-watch or watch-to-phone)
        watchConnectivityManager?.sendEmergencyState(
            state: currentState,
            contextId: activeContext?.id
        )
    }
}

// MARK: - Watch Connectivity Integration

/// Manages communication between iOS and watchOS devices
class WatchConnectivityManager: NSObject, WCSessionDelegate {
    private let session: WCSession
    private weak var emergencyDelegate: EmergencyStateDelegate?
    
    init(delegate: EmergencyStateDelegate) {
        self.session = WCSession.default
        self.emergencyDelegate = delegate
        
        super.init()
        
        // Configure session
        session.delegate = self
        session.activate()
    }
    
    func sendEmergencyState(state: EmergencyState, contextId: Int64?) {
        guard session.activationState == .activated else { return }
        
        var message: [String: Any] = ["emergencyState": state.rawValue]
        if let contextId = contextId {
            message["contextId"] = contextId
        }
        
        // For watchOS, ensure reachability
        #if os(watchOS)
        guard session.isReachable else {
            // Queue message for later delivery if companion unreachable
            session.transferUserInfo(message)
            return
        }
        #endif
        
        // Send immediate message
        session.sendMessage(message, replyHandler: nil) { error in
            print("Failed to sync emergency state: \(error.localizedDescription)")
            
            // Fall back to userInfo transfer which will deliver when possible
            self.session.transferUserInfo(message)
        }
    }
    
    // MARK: - WCSessionDelegate
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let stateString = message["emergencyState"] as? String,
              let state = EmergencyState(rawValue: stateString) else { return }
        
        let contextId = message["contextId"] as? Int64
        
        // Notify delegate of state change from companion
        DispatchQueue.main.async {
            self.emergencyDelegate?.didReceiveEmergencyStateUpdate(state: state, contextId: contextId)
        }
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Handle non-immediate message delivery
        guard let stateString = userInfo["emergencyState"] as? String,
              let state = EmergencyState(rawValue: stateString) else { return }
        
        let contextId = userInfo["contextId"] as? Int64
        
        DispatchQueue.main.async {
            self.emergencyDelegate?.didReceiveEmergencyStateUpdate(state: state, contextId: contextId)
        }
    }
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("WCSession activation failed: \(error.localizedDescription)")
        }
    }
    
    // Additional required delegate methods
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
    #endif
}

// MARK: - Emergency API Client

/// Handles communication with the backend emergency services
class EmergencyAPIClient {
    private let baseURL = URL(string: "https://api.example.com/api")!
    private let session = URLSession.shared
    
    /// Creates a new emergency context on the server
    func createEmergencyContext(
        userId: Int64,
        deviceId: String,
        deviceOrigin: String,
        emergencyType: String,
        activationMethod: String,
        completion: @escaping (Result<EmergencyContext, Error>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("emergency")
        
        // Prepare request body
        let body: [String: Any] = [
            "userId": userId,
            "deviceId": deviceId,
            "deviceOrigin": deviceOrigin,
            "emergencyType": emergencyType,
            "activationMethod": activationMethod
        ]
        
        // Execute POST request
        executeRequest(endpoint: endpoint, method: "POST", body: body, completion: completion)
    }
    
    /// Activates an emergency context with location
    func activateEmergency(
        contextId: Int64,
        latitude: Double? = nil,
        longitude: Double? = nil,
        completion: @escaping (Result<EmergencyContext, Error>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("emergency/\(contextId)/activate")
        
        // Include location if available
        var body: [String: Any] = [:]
        if let latitude = latitude, let longitude = longitude {
            body["latitude"] = latitude
            body["longitude"] = longitude
        }
        
        // Execute PUT request
        executeRequest(endpoint: endpoint, method: "PUT", body: body, completion: completion)
    }
    
    /// Cancels an emergency context
    func cancelEmergency(
        contextId: Int64,
        completion: @escaping (Result<EmergencyContext, Error>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("emergency/\(contextId)/cancel")
        
        // Execute PUT request with empty body
        executeRequest(endpoint: endpoint, method: "PUT", body: [:], completion: completion)
    }
    
    /// Begins recovery process
    func beginRecovery(
        contextId: Int64,
        completion: @escaping (Result<EmergencyContext, Error>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("emergency/\(contextId)/recover")
        
        // Execute PUT request with empty body
        executeRequest(endpoint: endpoint, method: "PUT", body: [:], completion: completion)
    }
    
    /// Completes recovery process
    func completeRecovery(
        contextId: Int64,
        completion: @escaping (Result<EmergencyContext, Error>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("emergency/\(contextId)/complete")
        
        // Execute PUT request with empty body
        executeRequest(endpoint: endpoint, method: "PUT", body: [:], completion: completion)
    }
    
    /// Updates location during an active emergency
    func updateLocation(
        contextId: Int64,
        latitude: Double,
        longitude: Double,
        completion: @escaping (Result<EmergencyContext, Error>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("emergency/\(contextId)/location")
        
        let body: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude
        ]
        
        // Execute POST request
        executeRequest(endpoint: endpoint, method: "POST", body: body, completion: completion)
    }
    
    /// Gets current emergency context from server
    func getEmergencyContext(
        contextId: Int64,
        completion: @escaping (Result<EmergencyContext, Error>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("emergency/\(contextId)")
        
        // Execute GET request
        executeRequest(endpoint: endpoint, method: "GET", body: nil, completion: completion)
    }
    
    // MARK: - Private Methods
    
    private func executeRequest<T: Decodable>(
        endpoint: URL,
        method: String,
        body: [String: Any]?,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add authentication token if available
        if let token = AuthManager.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // Add request body if provided
        if let body = body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                completion(.failure(error))
                return
            }
        }
        
        // Execute request
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(EmergencyError.invalidResponse))
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(EmergencyError.serverError(statusCode: httpResponse.statusCode)))
                return
            }
            
            guard let data = data else {
                completion(.failure(EmergencyError.noData))
                return
            }
            
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decodedObject = try decoder.decode(T.self, from: data)
                completion(.success(decodedObject))
            } catch {
                completion(.failure(error))
            }
        }
        
        task.resume()
    }
}

// MARK: - Location Manager

/// Manages location services for emergency tracking
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    
    var lastLocation: CLLocation?
    var didRequestPermission = false
    
    override init() {
        super.init()
        
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.pausesLocationUpdatesAutomatically = false
        
        // Enable background updates if this is an iOS app
        #if os(iOS)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        #endif
    }
    
    func requestLocationPermission() {
        guard !didRequestPermission else { return }
        
        locationManager.requestWhenInUseAuthorization()
        didRequestPermission = true
    }
    
    func startUpdatingLocation() {
        locationManager.startUpdatingLocation()
    }
    
    func startUpdatingHighAccuracyLocation() {
        // Configure for emergency high-accuracy tracking
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5 // meters
        locationManager.startUpdatingLocation()
    }
    
    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        lastLocation = location
        
        // Notify emergency manager of location update
        NotificationCenter.default.post(
            name: .locationDidUpdate,
            object: nil,
            userInfo: ["location": location]
        )
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed with error: \(error.localizedDescription)")
    }
}

// MARK: - Notification Manager

/// Manages push notifications and local alerts
class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let notificationCenter = UNUserNotificationCenter.current()
    
    override init() {
        super.init()
        
        notificationCenter.delegate = self
        
        // Request notification permissions
        requestNotificationPermission()
    }
    
    private func requestNotificationPermission() {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Failed to request notification permission: \(error.localizedDescription)")
            }
        }
    }
    
    func scheduleEmergencyAlert(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.defaultCritical
        content.categoryIdentifier = "EMERGENCY_ALERT"
        
        // Critical alert settings if authorized
        if #available(iOS 12.0, *) {
            content.sound = UNNotificationSound.defaultCritical
            content.relevanceScore = 1.0
        }
        
        // Schedule for immediate delivery
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        notificationCenter.add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Always show emergency alerts, even in foreground
        completionHandler([.alert, .sound])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Handle notification response
        if response.notification.request.content.categoryIdentifier == "EMERGENCY_ALERT" {
            // Open emergency screen
            NotificationCenter.default.post(name: .openEmergencyScreen, object: nil)
        }
        
        completionHandler()
    }
}

// MARK: - Protocols and Extensions

/// Protocol for receiving emergency state updates
protocol EmergencyStateDelegate: AnyObject {
    func didReceiveEmergencyStateUpdate(state: EmergencyState, contextId: Int64?)
}

/// EmergencySOSManager conformance to EmergencyStateDelegate
extension EmergencySOSManager: EmergencyStateDelegate {
    func didReceiveEmergencyStateUpdate(state: EmergencyState, contextId: Int64?) {
        // If we receive an update from companion device
        if let contextId = contextId {
            // If we don't have this context yet, fetch it
            if self.activeContext?.id != contextId {
                apiClient.getEmergencyContext(contextId: contextId) { [weak self] result in
                    if case .success(let context) = result {
                        self?.activeContext = context
                        self?.currentState = state
                        self?.persistEmergencyState()
                    }
                }
            } else {
                // Otherwise just update state
                self.currentState = state
                persistEmergencyState()
            }
        }
    }
}

/// Custom notification names
extension Notification.Name {
    static let emergencyStateChanged = Notification.Name("emergencyStateChanged")
    static let locationDidUpdate = Notification.Name("locationDidUpdate")
    static let openEmergencyScreen = Notification.Name("openEmergencyScreen")
}

/// Custom error types
enum EmergencyError: Error {
    case missingUserInformation
    case invalidResponse
    case serverError(statusCode: Int)
    case noData
    case invalidStateTransition
    case networkError
}

// MARK: - SwiftUI Integration

#if canImport(SwiftUI)
import SwiftUI

/// Main Emergency SOS interface view
struct EmergencySOSView: View {
    @ObservedObject private var emergencyManager = EmergencySOSManager.shared
    
    var body: some View {
        VStack(spacing: 20) {
            // Status indicator
            statusView
            
            Spacer()
            
            // Emergency controls
            controlsView
            
            Spacer()
            
            // Information
            informationView
        }
        .padding()
        .background(backgroundColorForState)
        .animation(.easeInOut, value: emergencyManager.currentState)
    }
    
    // Status view shows current emergency state
    private var statusView: some View {
        VStack(spacing: 10) {
            Circle()
                .fill(statusColorForState)
                .frame(width: 30, height: 30)
            
            Text(statusTextForState)
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
    }
    
    // Controls view shows appropriate buttons based on state
    private var controlsView: some View {
        Group {
            switch emergencyManager.currentState {
            case .inactive:
                emergencyButton
                
            case .pending:
                countdownView
                
            case .active:
                activeEmergencyControls
                
            case .recovering:
                recoveryControls
                
            case .cancelled:
                EmptyView()
            }
        }
    }
    
    // Main emergency activation button
    private var emergencyButton: some View {
        Button(action: {
            emergencyManager.initiateEmergency()
        }) {
            Text("Emergency SOS")
                .font(.title)
                .bold()
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red)
                .cornerRadius(15)
        }
        .padding(.horizontal, 40)
    }
    
    // Countdown display during pending state
    private var countdownView: some View {
        VStack(spacing: 30) {
            Text("Emergency SOS Activating in")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("\(emergencyManager.countdownRemaining)")
                .font(.system(size: 80, weight: .bold))
                .foregroundColor(.white)
            
            Button(action: {
                emergencyManager.cancelCountdown()
            }) {
                Text("Cancel")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.gray)
                    .cornerRadius(15)
            }
            .padding(.horizontal, 40)
        }
    }
    
    // Controls shown during active emergency
    private var activeEmergencyControls: some View {
        VStack(spacing: 20) {
            Text("Emergency Services Contacted")
                .font(.headline)
                .foregroundColor(.white)
            
            Button(action: {
                emergencyManager.beginRecovery()
            }) {
                Text("I'm Safe Now")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(15)
            }
            .padding(.horizontal, 40)
        }
    }
    
    // Controls shown during recovery phase
    private var recoveryControls: some View {
        VStack(spacing: 20) {
            Text("Recovery Mode")
                .font(.headline)
                .foregroundColor(.white)
            
            Button(action: {
                emergencyManager.completeRecovery()
            }) {
                Text("Complete Recovery")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(15)
            }
            .padding(.horizontal, 40)
        }
    }
    
    // Additional information display
    private var informationView: some View {
        VStack {
            if let error = emergencyManager.lastError {
                Text("Error: \(error.localizedDescription)")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding()
            }
        }
    }
    
    // Helper properties for UI state
    
    private var backgroundColorForState: Color {
        switch emergencyManager.currentState {
        case .inactive: return Color.black
        case .pending: return Color.orange
        case .active: return Color.red
        case .recovering: return Color.blue
        case .cancelled: return Color.black
        }
    }
    
    private var statusColorForState: Color {
        switch emergencyManager.currentState {
        case .inactive: return Color.gray
        case .pending: return Color.orange
        case .active: return Color.red
        case .recovering: return Color.blue
        case .cancelled: return Color.gray
        }
    }
    
    private var statusTextForState: String {
        switch emergencyManager.currentState {
        case .inactive: return "Ready"
        case .pending: return "Emergency Activation Pending"
        case .active: return "Emergency Active"
        case .recovering: return "Recovery Mode"
        case .cancelled: return "Emergency Cancelled"
        }
    }
}

/// Secondary view for Apple Watch implementation
#if os(watchOS)
struct EmergencySOSComplication: View {
    var body: some View {
        Button(action: {
            // Fast-path for watch: immediately activate emergency
            EmergencySOSManager.shared.activateEmergencyImmediately()
        }) {
            Image(systemName: "sos")
                .font(.title)
                .foregroundColor(.white)
        }
        .background(Color.red)
        .clipShape(Circle())
    }
}
#endif

#endif // canImport(SwiftUI)
