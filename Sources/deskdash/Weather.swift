import Foundation

struct WeatherReading: Equatable, Sendable {
    var temperature: Double
    var humidity: Double
    var code: Int  // WMO weather code
    var isDay: Bool
    var high: Double?
    var low: Double?
    var rainChance: Double?

    /// For `snapshot --demo`: a mild, partly cloudy day.
    static let demo = WeatherReading(temperature: 19, humidity: 64, code: 2, isDay: true, high: 22, low: 13, rainChance: 20)

    var symbol: String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

/// Outdoor conditions from Open-Meteo (free, no key), every 15 minutes, for the place chosen in Settings.
@MainActor
final class WeatherService {
    private let dash: Dashboard
    private var task: Task<Void, Never>?
    private var current: Config.Weather?

    init(dash: Dashboard) {
        self.dash = dash
    }

    func apply(_ cfg: Config.Weather) {
        guard cfg != current else { return }
        current = cfg
        task?.cancel()
        guard cfg.coordinates != nil else {
            dash.weather = nil
            return
        }
        task = Task {
            while !Task.isCancelled {
                let ok = await refresh(cfg)
                try? await Task.sleep(for: .seconds(ok ? 900 : 120))
            }
        }
    }

    private struct OpenMeteo: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let relative_humidity_2m: Double
            let weather_code: Int
            let is_day: Int?
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double?]?
            let temperature_2m_min: [Double?]?
            let precipitation_probability_max: [Double?]?
        }
        let current: Current
        let daily: Daily?
    }

    @discardableResult
    func refresh(_ cfg: Config.Weather) async -> Bool {
        guard let place = cfg.coordinates else { return false }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "temperature_unit", value: cfg.fahrenheit ? "fahrenheit" : "celsius"),
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: url.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let r = try JSONDecoder().decode(OpenMeteo.self, from: data)
            dash.weather = WeatherReading(
                temperature: r.current.temperature_2m,
                humidity: r.current.relative_humidity_2m,
                code: r.current.weather_code,
                isDay: (r.current.is_day ?? 1) == 1,
                high: r.daily?.temperature_2m_max?.first ?? nil,
                low: r.daily?.temperature_2m_min?.first ?? nil,
                rainChance: r.daily?.precipitation_probability_max?.first ?? nil)
            return true
        } catch {
            log("weather: \(error.localizedDescription)")
            return false
        }
    }
}
