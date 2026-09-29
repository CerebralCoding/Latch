import Foundation

struct TemperatureGuard: Codable, Equatable {
    var maxCPU = 55.0
    var maxGPU = 55.0
    var cooldown = 5.0

    func validate() throws {
        guard maxCPU.isFinite, maxGPU.isFinite, (1 ... 125).contains(maxCPU), (1 ... 125).contains(maxGPU),
              cooldown.isFinite, (0 ... 3600).contains(cooldown)
        else {
            throw LatchError("temperature limits must be 1–125 Celsius and cooldown 0–3600 seconds")
        }
    }

    func satisfied(by sensors: SensorSnapshot) -> Bool {
        guard let cpu = sensors.cpuTemperature, let gpu = sensors.gpuTemperature,
              cpu.isFinite, gpu.isFinite, cpu > 0, gpu > 0 else { return false }
        return cpu <= maxCPU && gpu <= maxGPU && sensors.thermalState == "nominal"
    }

    func reason(sensors: SensorSnapshot, since: Double?) -> String? {
        guard let cpu = sensors.cpuTemperature, let gpu = sensors.gpuTemperature else {
            return "CPU/GPU temperature sensors unavailable"
        }
        guard satisfied(by: sensors) else {
            return "temperature guard: CPU \(String(format: "%.1f", cpu))/\(maxCPU) C, GPU \(String(format: "%.1f", gpu))/\(maxGPU) C"
        }
        if cooldown == 0 {
            return nil
        }
        guard let since, sensors.uptime >= since, sensors.uptime - since >= cooldown else {
            return "waiting for \(cooldown) seconds below temperature limits"
        }
        return nil
    }
}
