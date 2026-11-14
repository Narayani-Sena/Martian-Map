class_name SuitModel
extends RefCounted
## The suit atmosphere: pressure, ppO2 and inspired CO2 (NASA-STD-3001 Vol 2 [V2 11035] display,
## [V2 11036] alarm, [V2 11040] the 20 mmHg contingency CO2 limit). The same formulas as server/eva.py
## (tests/test_godot_suit.py checks they agree). All values are planning assumptions, shown as such.
##
## Drills inject faults: "leak" (suit pressure falls 2.4 kPa a minute until the secondary oxygen pack holds
## it at 24 kPa) and "co2" (the scrubber cartridge breaks through: its load climbs 1.5 % a second).

const SUIT_P_KPA := 29.6      # 4.3 psi pure-oxygen suit (EMU / xEMU)
const PPH2O_KPA := 1.6
const MMHG_PER_KPA := 7.50062
const KPA_PER_PSI := 6.894757
# alarm levels (the planner's GO/NO-GO uses the same CO2 numbers)
const PPCO2_CAUTION := 8.0    # mmHg: above the normal operating range
const PPCO2_WARNING := 15.0   # mmHg: approaching NASA's contingency limit
const PPCO2_LIMIT := 20.0     # mmHg: NASA's contingency limit, up to 1 hour [V2 11040]
const P_CAUTION := 27.6       # kPa (4.0 psi)
const P_WARNING := 25.5       # kPa (3.7 psi)
const P_EMERGENCY := 20.7     # kPa (3.0 psi)
const P_DROP_RATE := 0.7      # kPa a minute: falling faster than this is a leak (emergency)
const PPO2_CAUTION := 22.0    # kPa
const PPO2_WARNING := 18.0    # kPa (hypoxia risk)
const SOP_HOLD_KPA := 24.0    # where the secondary oxygen pack holds a leaking suit


static func ppco2_mmhg(met_w: float, scrubber_load_pct: float) -> float:
	var washout := 1.6 * maxf(0.0, met_w) / 300.0
	var x := maxf(0.0, (scrubber_load_pct - 70.0) / 30.0)
	return washout + 20.0 * x * x


static func ppo2_kpa(p_suit_kpa: float, ppco2: float) -> float:
	return p_suit_kpa - PPH2O_KPA - ppco2 / MMHG_PER_KPA


## Suit pressure with a drill running for `fault_s` seconds (the regulator's tiny ripple otherwise).
static func pressure_kpa(fault: String, fault_s: float, clock_s: float) -> float:
	var p := SUIT_P_KPA + 0.03 * sin(clock_s * 0.7)
	if fault == "leak":
		p = maxf(SOP_HOLD_KPA, SUIT_P_KPA - 2.4 * fault_s / 60.0)
	return p


## Scrubber load with a drill running: a breakthrough climbs 1.5 % a second.
static func scrubber_load(load_pct: float, fault: String, fault_s: float) -> float:
	if fault == "co2":
		return minf(100.0, maxf(load_pct, 70.0) + 1.5 * fault_s)
	return load_pct


static func fmt_pressure(kpa: float, unit: String) -> String:
	if unit == "psi":
		return "%.2f psi" % (kpa / KPA_PER_PSI)
	return "%.1f kPa" % kpa
