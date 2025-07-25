// swiftlint:disable type_body_length
import Foundation
import CoreBluetooth

class Device: NSObject, CBPeripheralDelegate {
    typealias Callback = (_ success: Bool, _ value: String) -> Void

    private var peripheral: CBPeripheral!
    private var callbackMap = ThreadSafeDictionary<String, Callback>()
    private var timeoutMap = [String: DispatchWorkItem]()
    private var servicesCount = 0
    private var servicesDiscovered = 0
    private var characteristicsCount = 0
    private var characteristicsDiscovered = 0

    // Các thuộc tính được thêm vào để xử lý thông báo cụ thể
    private var targetServiceUUID: CBUUID?
    private var targetCharacteristicUUID: CBUUID?
    private var pendingNotificationEnable: Bool = false
    // Thêm biến kiểm soát trạng thái notify pending
    private var notificationPending = [String: Bool]() // Dùng để theo dõi yêu cầu notify đang chờ

    init(
        _ peripheral: CBPeripheral
    ) {
        super.init()
        self.peripheral = peripheral
        self.peripheral.delegate = self
    }

    func getName() -> String? {
        return self.peripheral.name
    }

    func getId() -> String {
        return self.peripheral.identifier.uuidString
    }

    func isConnected() -> Bool {
        return self.peripheral.state == CBPeripheralState.connected
    }

    func getPeripheral() -> CBPeripheral {
        return self.peripheral
    }

    func setOnConnected(
        _ connectionTimeout: Double,
        _ callback: @escaping Callback
    ) {
        let key = "connect"
        self.callbackMap[key] = callback
        self.setTimeout(key, "Connection timeout", connectionTimeout)
    }

    // MARK: - CBPeripheralDelegate Methods

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        log("Discovered services: \(peripheral.services?.map { $0.uuid.uuidString } ?? [])")
        if error != nil {
            log("Error discovering services: \(error!.localizedDescription)")
            // Cần reject callback nếu có lỗi
            if let serviceUUID = targetServiceUUID, let characteristicUUID = targetCharacteristicUUID {
                let key = "setNotifications|\(serviceUUID.uuidString.lowercased())|\(characteristicUUID.uuidString.lowercased())"
                self.reject(key, "Service discovery failed: \(error!.localizedDescription)")
                self.notificationPending[key] = false // Clear pending state on error
            }
            return
        }

        // Logic để tìm service mục tiêu cho thông báo
        if let serviceUUID = targetServiceUUID,
           let characteristicUUID = targetCharacteristicUUID,
           let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {

            log("Found target service: \(serviceUUID.uuidString), discovering characteristics...")
            // Chỉ khám phá đặc tính mục tiêu thay vì tất cả
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        } else {
            // Hành vi ban đầu để khám phá tất cả các service và đặc tính
            // Cân nhắc liệu bạn có cần khám phá tất cả nếu chỉ muốn set notifications
            self.servicesCount = peripheral.services?.count ?? 0
            self.servicesDiscovered = 0
            self.characteristicsCount = 0
            self.characteristicsDiscovered = 0

            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service) // Khám phá tất cả đặc tính cho mỗi service
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error = error {
            log("Error discovering characteristics for service \(service.uuid.uuidString): \(error.localizedDescription)")
            // Cần reject callback nếu có lỗi
            if let serviceUUID = targetServiceUUID, let characteristicUUID = targetCharacteristicUUID {
                let key = "setNotifications|\(serviceUUID.uuidString.lowercased())|\(characteristicUUID.uuidString.lowercased())"
                self.reject(key, "Characteristic discovery failed: \(error.localizedDescription)")
                self.notificationPending[key] = false // Clear pending state on error
            }
            return
        }

        log("Discovered characteristics for service \(service.uuid.uuidString): \(service.characteristics?.map { $0.uuid.uuidString } ?? [])")

        // Kiểm tra xem đây có phải là service mà chúng ta quan tâm để thiết lập thông báo không
        if let targetServiceUUID = targetServiceUUID,
           let targetCharacteristicUUID = targetCharacteristicUUID,
           service.uuid == targetServiceUUID {

            if let characteristic = service.characteristics?.first(where: { $0.uuid == targetCharacteristicUUID }) {
                log("Found target characteristic: \(targetCharacteristicUUID.uuidString), setting notification: \(pendingNotificationEnable)")

                // Loại bỏ delay không cần thiết này. setNotifyValue nên được gọi ngay lập tức.
                // DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                peripheral.setNotifyValue(self.pendingNotificationEnable, for: characteristic)
                // }

                // RẤT QUAN TRỌNG: Reset các UUID mục tiêu sau khi đã tìm thấy và thiết lập.
                // Nếu không, các cuộc gọi setNotifications tiếp theo có thể bị ảnh hưởng bởi các giá trị cũ.
                self.targetServiceUUID = nil
                self.targetCharacteristicUUID = nil
                return // Tránh chạy logic khám phá chung nếu đây là mục tiêu cụ thể
            } else {
                log("Target characteristic \(targetCharacteristicUUID.uuidString) not found in service \(service.uuid.uuidString)")
                // Reject callback nếu không tìm thấy đặc tính mục tiêu
                let key = "setNotifications|\(targetServiceUUID.uuidString.lowercased())|\(targetCharacteristicUUID.uuidString.lowercased())"
                self.reject(key, "Target characteristic not found.")
                self.notificationPending[key] = false // Clear pending state on error
            }
        }

        // Hành vi ban đầu cho việc khám phá đặc tính chung
        self.servicesDiscovered += 1
        self.characteristicsCount += service.characteristics?.count ?? 0

        for characteristic in service.characteristics ?? [] {
            peripheral.discoverDescriptors(for: characteristic)
        }

        // Nếu đây là service cuối cùng, giải quyết kết nối (hoặc discoverServices)
        // Cần xem xét lại logic này nếu bạn chỉ muốn discover cho setNotifications
        if self.servicesDiscovered >= self.servicesCount && self.characteristicsDiscovered >= self.characteristicsCount {
            self.resolve("discoverServices", "Services discovered.")
            self.resolve("connect", "Connection successful.") // Có thể đã được resolve bởi setOnConnected
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Logic này chủ yếu cho việc khám phá chung, không trực tiếp cho setNotifications
        self.characteristicsDiscovered += 1
        if self.servicesDiscovered >= self.servicesCount && self.characteristicsDiscovered >= self.characteristicsCount {
            self.resolve("connect", "Connection successful.")
            self.resolve("discoverServices", "Services discovered.")
        }
    }

    func getServices() -> [CBService] {
        return self.peripheral.services ?? []
    }

    func discoverServices(
        _ timeout: Double,
        _ callback: @escaping Callback
    ) {
        let key = "discoverServices"
        self.callbackMap[key] = callback
        self.peripheral.discoverServices(nil)
        self.setTimeout(key, "Service discovery timeout.", timeout)
    }

    func getMtu() -> Int {
        // maximumWriteValueLength is 3 bytes less than ATT MTU
        return self.peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
    }

    func readRssi(
        _ timeout: Double,
        _ callback: @escaping Callback
    ) {
        let key = "readRssi"
        self.callbackMap[key] = callback
        log("Reading RSSI value")
        self.peripheral.readRSSI()
        self.setTimeout(key, "Reading RSSI timeout.", timeout)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: Error?
    ) {
        let key = "readRssi"
        if error != nil {
            self.reject(key, error!.localizedDescription)
            return
        }
        self.resolve(key, RSSI.stringValue)
    }

    private func getCharacteristic(
        _ serviceUUID: CBUUID,
        _ characteristicUUID: CBUUID
    ) -> CBCharacteristic? {
        // Nên đảm bảo services đã được khám phá trước khi gọi hàm này
        // Hoặc thêm logic khám phá nếu chưa có
        for service in peripheral.services ?? [] {
            if service.uuid == serviceUUID {
                log("Service found: \(service.uuid)")
                for characteristic in service.characteristics ?? [] {
                    log("Characteristic found: \(characteristic.uuid), properties: \(characteristic.properties.rawValue)")
                    if characteristic.uuid == characteristicUUID {
                        return characteristic
                    }
                }
            }
        }
        return nil
    }

    private func getDescriptor(
        _ serviceUUID: CBUUID,
        _ characteristicUUID: CBUUID,
        _ descriptorUUID: CBUUID
    ) -> CBDescriptor? {
        guard let characteristic = self.getCharacteristic(serviceUUID, characteristicUUID) else {
            return nil
        }
        for descriptor in characteristic.descriptors ?? [] {
            if descriptor.uuid == descriptorUUID {
                return descriptor
            }
        }
        return nil
    }

    func read(
        _ serviceUUID: CBUUID,
        _ characteristicUUID: CBUUID,
        _ timeout: Double,
        _ callback: @escaping Callback
    ) {
        let key = "read|\(serviceUUID.uuidString)|\(characteristicUUID.uuidString)"
        self.callbackMap[key] = callback
        guard let characteristic = self.getCharacteristic(serviceUUID, characteristicUUID) else {
            self.reject(key, "Characteristic not found.")
            return
        }
        log("Reading value")
        self.peripheral.readValue(for: characteristic)
        self.setTimeout(key, "Read timeout.", timeout)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = self.getKey("read", characteristic)
        let notifyKey = self.getKey("notification", characteristic)
        if error != nil {
            self.reject(key, error!.localizedDescription)
            return
        }
        if characteristic.value == nil {
            self.reject(key, "Characteristic contains no value.")
            return
        }
        // reading
        let valueString = dataToString(characteristic.value!)
        self.resolve(key, valueString)

        // notifications
        let callback = self.callbackMap[notifyKey]
        if callback != nil {
            callback!(true, valueString)
        }
    }

    func readDescriptor(
        _ serviceUUID: CBUUID,
        _ characteristicUUID: CBUUID,
        _ descriptorUUID: CBUUID,
        _ timeout: Double,
        _ callback: @escaping Callback
    ) {
        let key = "readDescriptor|\(serviceUUID.uuidString)|\(characteristicUUID.uuidString)|\(descriptorUUID.uuidString)"
        self.callbackMap[key] = callback
        guard let descriptor = self.getDescriptor(serviceUUID, characteristicUUID, descriptorUUID) else {
            self.reject(key, "Descriptor not found.")
            return
        }
        log("Reading descriptor value")
        self.peripheral.readValue(for: descriptor)
        self.setTimeout(key, "Read descriptor timeout.", timeout)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor descriptor: CBDescriptor,
        error: Error?
    ) {
        let key = self.getKey("readDescriptor", descriptor)
        if error != nil {
            self.reject(key, error!.localizedDescription)
            return
        }
        if descriptor.value == nil {
            self.reject(key, "Descriptor contains no value.")
            return
        }
        let valueString = descriptorValueToString(descriptor.value!)
        self.resolve(key, valueString)
    }

    func write(
        _ serviceUUID: CBUUID,
        _ characteristicUUID: CBUUID,
        _ value: String,
        _ writeType: CBCharacteristicWriteType,
        _ timeout: Double,
        _ callback: @escaping Callback
    ) {
        let key = "write|\(serviceUUID.uuidString)|\(characteristicUUID.uuidString)"
        self.callbackMap[key] = callback
        guard let characteristic = self.getCharacteristic(serviceUUID, characteristicUUID) else {
            self.reject(key, "Characteristic not found.")
            return
        }
        let data: Data = stringToData(value)
        self.peripheral.writeValue(data, for: characteristic, type: writeType)
        if writeType == CBCharacteristicWriteType.withResponse {
            self.setTimeout(key, "Write timeout.", timeout)
        } else {
            self.resolve(key, "Successfully written value.")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = self.getKey("write", characteristic)
        if error != nil {
            self.reject(key, error!.localizedDescription)
            return
        }
        self.resolve(key, "Successfully written value.")
    }

    func writeDescriptor(
        _ serviceUUID: CBUUID,
        _ characteristicUUID: CBUUID,
        _ descriptorUUID: CBUUID,
        _ value: String,
        _ timeout: Double,
        _ callback: @escaping Callback
    ) {
        let key = "writeDescriptor|\(serviceUUID.uuidString)|\(characteristicUUID.uuidString)|\(descriptorUUID.uuidString)"
        self.callbackMap[key] = callback
        guard let descriptor = self.getDescriptor(serviceUUID, characteristicUUID, descriptorUUID) else {
            self.reject(key, "Descriptor not found.")
            return
        }
        let data: Data = stringToData(value)
        self.peripheral.writeValue(data, for: descriptor)
        self.setTimeout(key, "Write descriptor timeout.", timeout)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor descriptor: CBDescriptor,
        error: Error?
    ) {
        let key = self.getKey("writeDescriptor", descriptor)
        if error != nil {
            self.reject(key, error!.localizedDescription)
            return
        }
        self.resolve(key, "Successfully written descriptor value.")
    }

    func setNotifications(
        _ serviceUUID: CBUUID,
        _ characteristicUUID: CBUUID,
        _ enable: Bool,
        _ notifyCallback: Callback?,
        _ timeout: Double, // Timeout được truyền vào
        _ callback: @escaping Callback // Callback cho việc thiết lập thành công/thất bại
    ) {
        let key = "setNotifications|\(serviceUUID.uuidString.lowercased())|\(characteristicUUID.uuidString.lowercased())"
        let notifyKey = "notification|\(serviceUUID.uuidString.lowercased())|\(characteristicUUID.uuidString.lowercased())"

        // Kiểm tra trạng thái pending để tránh gửi nhiều yêu cầu cùng lúc
        if notificationPending[key] == true {
            self.reject(key, "Notification request is pending for this characteristic.")
            return
        }
        notificationPending[key] = true // Đặt trạng thái pending

        log("Setting up notifications: \(enable) for service: \(serviceUUID.uuidString), characteristic: \(characteristicUUID.uuidString)")

        self.callbackMap[key] = callback // Lưu callback cho việc thiết lập
        if let notifyCallback = notifyCallback {
            log("Setting up notify callback for service: \(serviceUUID.uuidString), characteristic: \(characteristicUUID.uuidString)")
            self.callbackMap[notifyKey] = notifyCallback // Lưu callback cho dữ liệu notify
        }

        // Lưu các UUID mục tiêu và trạng thái thông báo
        self.targetServiceUUID = serviceUUID
        self.targetCharacteristicUUID = characteristicUUID
        self.pendingNotificationEnable = enable

        // Bắt đầu khám phá service
        if peripheral.state == .connected {
            log("Starting service discovery for UUID: \(serviceUUID.uuidString)")
            peripheral.discoverServices([serviceUUID]) // Chỉ khám phá service mục tiêu
            // Đặt timeout chính cho toàn bộ quá trình thiết lập thông báo
            self.setTimeout(key, "Set notifications timeout.", timeout)
        } else {
            self.reject(key, "Peripheral is not connected. Current state: \(peripheral.state.rawValue)")
            notificationPending[key] = false // Clear pending state if not connected
        }

        // LOẠI BỎ KHỐI DISPATCHQUEUE.MAIN.ASYNCAFTER CÓ TIMEOUT CỐ ĐỊNH NÀY!
        // Nó đang gây ra timeout sớm và xung đột với setTimeout chính.
        // DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        //     if self.notificationPending[key] == true {
        //         self.notificationPending[key] = false
        //         log("Set notifications timeout for key: \(key)")
        //         self.reject(key, "Set notifications timeout.")
        //     }
        // }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let serviceUUID = characteristic.service?.uuid else {
            log("Error: Service for characteristic \(characteristic.uuid.uuidString) is nil in didUpdateNotificationStateFor.")
            return
        }

        let characteristicUUID = characteristic.uuid
        let key = "setNotifications|\(serviceUUID.uuidString.lowercased())|\(characteristicUUID.uuidString.lowercased())"
        log("==> didUpdateNotificationStateFor fired for service: \(characteristic.service?.uuid.uuidString ?? "nil"), char: \(characteristic.uuid.uuidString), error: \(String(describing: error)), isNotifying: \(characteristic.isNotifying)")
        // RẤT QUAN TRỌNG: Xóa trạng thái pending và hủy timeout ngay khi nhận được phản hồi
        self.notificationPending[key] = false
        self.timeoutMap[key]?.cancel() // Hủy timeout chính
        self.timeoutMap[key] = nil

        if let error = error {
            self.reject(key, "Failed to update notification state: \(error.localizedDescription)")
            return
        }

        // Thông báo/chỉ định đã được thiết lập thành công
        self.resolve(key, "Successfully set notification state to \(characteristic.isNotifying)")
    }

    // MARK: - Helper Methods

    private func getKey(
        _ prefix: String,
        _ characteristic: CBCharacteristic?
    ) -> String {
        let serviceUUIDString: String
        let service: CBService? = characteristic?.service
        if service != nil {
            serviceUUIDString = cbuuidToStringUppercase(service!.uuid)
        } else {
            serviceUUIDString = "UNKNOWN-SERVICE"
        }
        let characteristicUUIDString: String
        if characteristic != nil {
            characteristicUUIDString = cbuuidToStringUppercase(characteristic!.uuid)
        } else {
            characteristicUUIDString = "UNKNOWN-CHARACTERISTIC"
        }
        return "\(prefix)|\(serviceUUIDString)|\(characteristicUUIDString)"
    }

    private func getKey(
        _ prefix: String,
        _ descriptor: CBDescriptor
    ) -> String {
        let baseKey = self.getKey(prefix, descriptor.characteristic)
        let descriptorUUIDString = cbuuidToStringUppercase(descriptor.uuid)
        return "\(baseKey)|\(descriptorUUIDString)"
    }

    private func resolve(
        _ key: String,
        _ value: String
    ) {
        let callback = self.callbackMap[key]
        if callback != nil {
            log("Resolve", key, value)
            callback!(true, value)
            self.callbackMap[key] = nil
            self.timeoutMap[key]?.cancel()
            self.timeoutMap[key] = nil
        }
    }

    private func reject(
        _ key: String,
        _ value: String
    ) {
        let callback = self.callbackMap[key]
        if callback != nil {
            log("Reject", key, value)
            callback!(false, value)
            self.callbackMap[key] = nil
            self.timeoutMap[key]?.cancel()
            self.timeoutMap[key] = nil
        }
    }

    private func setTimeout(
        _ key: String,
        _ message: String,
        _ timeout: Double
    ) {
        let workItem = DispatchWorkItem {
            self.reject(key, message)
        }
        self.timeoutMap[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }
}
