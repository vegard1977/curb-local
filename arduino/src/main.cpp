#include <Arduino.h>
#include <OneWire.h>
#include <DallasTemperature.h>

// ── Pin-konfigurasjoner ───────────────────────────────────────────────────────
static const uint8_t ONE_WIRE_PIN = 2;    // DS18B20 data (4.7kΩ pull-up til 5V)
static const uint8_t NUM_TEMP     = 2;    // Antall DS18B20-sensorer
static const uint8_t NUM_CT       = 16;   // Antall CT-clamps (alle analoge innganger)

// CT-clamp analog-pinner A0–A15 (alle 16 analoge innganger på Mega)
// Kobling per kanal: CT 3.5mm tip → 10µF kap → pin, 2×10kΩ bias til 2.5V
static const uint8_t CT_PINS[NUM_CT] = {
    A0, A1, A2, A3, A4, A5, A6, A7,
    A8, A9, A10, A11, A12, A13, A14, A15
};

OneWire      oneWire(ONE_WIRE_PIN);
DallasTemperature sensors(&oneWire);

void setup() {
    Serial.begin(115200);
    sensors.begin();
    sensors.setResolution(11);  // 11-bit: 375ms konverteringstid, 0.125°C oppløsning

    uint8_t found = sensors.getDeviceCount();
    Serial.print(F("# DS18B20 funnet: "));
    Serial.println(found);
}

// ── CT-lesing (placeholder til Shelly 50A-clamps ankommer) ───────────────────
// Shelly 50A CT: innebygd burden, 1V AC RMS ved 50A.
// Når hardware er klar: erstatt med EmonLib
//   #include <EmonLib.h>
//   EnergyMonitor ct[NUM_CT];
//   ct[i].current(CT_PINS[i], 50.0);  // kalibrer mot kjent last
//   float amps = ct[i].calcIrms(1480);
static float read_ct(uint8_t /*pin*/) {
    return 1.13f;  // placeholder — erstattes med EmonLib RMS-lesing
}

void loop() {
    sensors.requestTemperatures();  // blokkerer ~375ms ved 11-bit

    // JSON-linje til Curb (en linje per sekund)
    // Format: {"t":[temp0,temp1],"a":[a0,...,a8]}
    Serial.print(F("{\"t\":["));
    for (uint8_t i = 0; i < NUM_TEMP; i++) {
        if (i > 0) Serial.print(',');
        float t = sensors.getTempCByIndex(i);
        if (t == DEVICE_DISCONNECTED_C) {
            Serial.print(F("null"));
        } else {
            Serial.print(t, 2);
        }
    }

    Serial.print(F("],\"a\":["));
    for (uint8_t i = 0; i < NUM_CT; i++) {
        if (i > 0) Serial.print(',');
        Serial.print(read_ct(CT_PINS[i]), 2);
    }

    Serial.println(F("]}"));

    delay(650);  // ~1 Hz totalt (375ms konvertering + 650ms = ~1025ms)
}
