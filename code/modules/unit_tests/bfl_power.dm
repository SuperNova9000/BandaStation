/// Юнит-тесты установки BFL (Beam Freight Laser).
///
/// Проверяются: таблицы режимов, отбор мощности из сети, ограничение доли
/// отбора, просадка сети, тепловая модель, охлаждение контуром и начисление
/// кредитов.

// ---------------------------------------------------------------------------
// Вспомогательные процедуры
// ---------------------------------------------------------------------------

/// Создаёт эмиттер BFL, подключённый к энергосети с заданным свободным
/// запасом мощности. Возвращает список [эмиттер, powernet].
/datum/unit_test/proc/setup_bfl_emitter(mode = BFL_MODE_1, avail_energy = 10 MEGA JOULES)
	var/obj/machinery/power/bfl/emitter/emitter = allocate(/obj/machinery/power/bfl/emitter)
	var/datum/powernet/network = new /datum/powernet()
	// avail и newavail: powernet.reset() переносит newavail в avail.
	network.avail = avail_energy
	network.newavail = avail_energy
	emitter.powernet = network
	emitter.mode = mode
	emitter.state = BFL_STATE_ONLINE
	return list(emitter, network)

/// Создаёт порт охлаждения с контуром, заполненным заданным газом.
/// Возвращает список [порт, конвейер].
/datum/unit_test/proc/setup_bfl_coolant_port(moles = 8, gas_type = /datum/gas/nitrogen, temperature = 300)
	var/obj/machinery/atmospherics/components/unary/bfl_coolant_port/port = allocate(/obj/machinery/atmospherics/components/unary/bfl_coolant_port)
	var/datum/pipeline/loop = new /datum/pipeline()
	loop.air = new /datum/gas_mixture(200)
	loop.air.temperature = temperature
	loop.air.moles[gas_type] = moles
	port.parents[1] = loop
	return list(port, loop)

// ---------------------------------------------------------------------------
// Таблицы режимов
// ---------------------------------------------------------------------------

/datum/unit_test/bfl_mode_tables
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_mode_tables/Run()
	var/obj/machinery/power/bfl/emitter/emitter = allocate(/obj/machinery/power/bfl/emitter)

	TEST_ASSERT_EQUAL(emitter.get_mode_power(BFL_MODE_OFF), 0, "Выключенная установка не должна потреблять мощность.")

	TEST_ASSERT_EQUAL(emitter.get_mode_power(BFL_MODE_1), BFL_MODE_POWER_1, "Мощность режима 1 не совпадает с таблицей.")
	TEST_ASSERT_EQUAL(emitter.get_mode_power(BFL_MODE_2), BFL_MODE_POWER_2, "Мощность режима 2 не совпадает с таблицей.")
	TEST_ASSERT_EQUAL(emitter.get_mode_power(BFL_MODE_3), BFL_MODE_POWER_3, "Мощность режима 3 не совпадает с таблицей.")
	TEST_ASSERT_EQUAL(emitter.get_mode_power(BFL_MODE_4), BFL_MODE_POWER_4, "Мощность режима 4 не совпадает с таблицей.")
	TEST_ASSERT_EQUAL(emitter.get_mode_power(BFL_MODE_5), BFL_MODE_POWER_5, "Мощность режима 5 не совпадает с таблицей.")

	TEST_ASSERT_EQUAL(emitter.get_base_tariff(BFL_MODE_1), BFL_TARIFF_1, "Тариф режима 1 не совпадает с таблицей.")
	TEST_ASSERT_EQUAL(emitter.get_base_tariff(BFL_MODE_5), BFL_TARIFF_5, "Тариф режима 5 не совпадает с таблицей.")
	TEST_ASSERT_EQUAL(emitter.get_base_tariff(BFL_MODE_OFF), 0, "У выключенной установки нет тарифа.")

	// КПД без повреждений.
	emitter.mode = BFL_MODE_1
	TEST_ASSERT_EQUAL(emitter.get_efficiency(), BFL_MODE_EFFICIENCY_1, "КПД режима 1 не совпадает с таблицей.")
	emitter.mode = BFL_MODE_5
	TEST_ASSERT_EQUAL(emitter.get_efficiency(), BFL_MODE_EFFICIENCY_5, "КПД режима 5 не совпадает с таблицей.")

	// Повреждения снижают КПД.
	emitter.damage = 50
	TEST_ASSERT(emitter.get_efficiency() < BFL_MODE_EFFICIENCY_5, "Повреждения должны снижать КПД.")
	emitter.damage = 0

	// Режимы вне диапазона недопустимы.
	TEST_ASSERT_EQUAL(emitter.set_mode(BFL_MODE_OFF), FALSE, "Режим 0 не должен приниматься.")
	TEST_ASSERT_EQUAL(emitter.set_mode(BFL_MODE_MAX + 1), FALSE, "Режим выше максимального не должен приниматься.")
	TEST_ASSERT_EQUAL(emitter.set_mode(BFL_MODE_MIN), TRUE, "Рабочий режим должен приниматься.")
	TEST_ASSERT_EQUAL(emitter.mode, BFL_MODE_MIN, "Режим не должен устанавливаться.")

	return TRUE

// ---------------------------------------------------------------------------
// Отбор мощности из сети
// ---------------------------------------------------------------------------

/datum/unit_test/bfl_energy_transfer
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_energy_transfer/Run()
	var/list/setup = setup_bfl_emitter(BFL_MODE_1, 10 MEGA JOULES)
	var/obj/machinery/power/bfl/emitter/emitter = setup[1]
	var/datum/powernet/network = setup[2]

	var/requested = power_to_energy(BFL_MODE_POWER_1)
	var/expected_taken = min(requested, (10 MEGA JOULES) * BFL_MAX_GRID_SHARE)

	emitter.process(2)

	TEST_ASSERT_EQUAL(network.load, expected_taken, "Установка должна забрать ровно запрошенную мощность.")
	TEST_ASSERT_EQUAL(emitter.total_energy_transmitted, expected_taken * BFL_MODE_EFFICIENCY_1, "Переданная энергия не соответствует КПД.")
	TEST_ASSERT_EQUAL(emitter.core_heat, expected_taken - expected_taken * BFL_MODE_EFFICIENCY_1, "Тепло в ядре не соответствует потерям на КПД.")

	return TRUE

// ---------------------------------------------------------------------------
// Ограничение доли отбора
// ---------------------------------------------------------------------------

/datum/unit_test/bfl_grid_share_limit
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_grid_share_limit/Run()
	// Сети хватает только на 1 МДж, а режим 5 требует намного больше.
	var/list/setup = setup_bfl_emitter(BFL_MODE_5, 1 MEGA JOULES)
	var/obj/machinery/power/bfl/emitter/emitter = setup[1]
	var/datum/powernet/network = setup[2]

	emitter.process(2)

	var/allowed = (1 MEGA JOULES) * BFL_MAX_GRID_SHARE
	TEST_ASSERT_EQUAL(network.load, allowed, "Установка не должна забирать больше доли свободной мощности.")
	TEST_ASSERT(network.load < power_to_energy(BFL_MODE_POWER_5), "Установка не должна забирать больше запрошенного.")

	return TRUE

// ---------------------------------------------------------------------------
// Просадка сети
// ---------------------------------------------------------------------------

/datum/unit_test/bfl_grid_sag
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_grid_sag/Run()
	var/list/setup = setup_bfl_emitter(BFL_MODE_3, 0)
	var/obj/machinery/power/bfl/emitter/emitter = setup[1]

	TEST_ASSERT_EQUAL(emitter.mode, BFL_MODE_3, "Режим должен изначально соответствовать заданному.")

	// Сети нет: после нескольких тиков подряд режим должен снизиться.
	for(var/i in 1 to BFL_GRID_SAG_TICKS)
		emitter.process(2)

	TEST_ASSERT_EQUAL(emitter.mode, BFL_MODE_3 - 1, "При устойчивой просадке сети режим должен снизиться.")

	return TRUE

// ---------------------------------------------------------------------------
// Деградация тарифа
// ---------------------------------------------------------------------------

/datum/unit_test/bfl_tariff_decay
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_tariff_decay/Run()
	var/obj/machinery/power/bfl/emitter/emitter = allocate(/obj/machinery/power/bfl/emitter)
	emitter.mode = BFL_MODE_3

	TEST_ASSERT_EQUAL(emitter.get_tariff(), BFL_TARIFF_3, "До насыщения рынка тариф должен быть базовым.")

	emitter.total_energy_transmitted = BFL_TARIFF_DECAY_THRESHOLD
	TEST_ASSERT_EQUAL(emitter.get_tariff(), BFL_TARIFF_3 * BFL_TARIFF_DECAY_FACTOR, "После насыщения рынка тариф должен снизиться.")

	return TRUE

// ---------------------------------------------------------------------------
// Тепловая модель и аварийный сброс
// ---------------------------------------------------------------------------

/datum/unit_test/bfl_thermal_scram
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_thermal_scram/Run()
	var/list/setup = setup_bfl_emitter(BFL_MODE_5, 100 MEGA JOULES)
	var/obj/machinery/power/bfl/emitter/emitter = setup[1]
	var/datum/powernet/network = setup[2]

	// Без порта охлаждения ядро должно перегреться и уйти в аварийный сброс.
	// load сбрасывается каждый тик (так делает powernet.reset()), поэтому
	// имитируем сброс, иначе свободная мощность исчерпается и тест замрёт.
	var/ticks = 0
	while(emitter.state == BFL_STATE_ONLINE && ticks < 500)
		network.load = 0
		network.avail = 100 MEGA JOULES
		emitter.process(2)
		ticks++

	TEST_ASSERT_NOTEQUAL(emitter.state, BFL_STATE_ONLINE, "Без охлаждения установка обязана уйти из рабочего режима.")
	TEST_ASSERT_EQUAL(emitter.state, BFL_STATE_SCRAM, "Перегрев должен приводить к аварийному сбросу, а не к разрушению.")
	TEST_ASSERT(emitter.core_temperature >= BFL_TEMP_CRITICAL, "Температура ядра должна была превысить критическую.")
	TEST_ASSERT(emitter.damage > 0, "Перегрев должен накапливать повреждения.")

	// После сброса тепло остаётся в ядре — его всё равно нужно отвести.
	TEST_ASSERT(emitter.core_heat > 0, "После аварийного сброса тепло должно оставаться в ядре.")

	return TRUE

// ---------------------------------------------------------------------------
// Катастрофа после аварийного сброса
// ---------------------------------------------------------------------------

/// Аварийный сброс гасит пучок, но не отменяет накопление тепла:
/// катастрофа должна оставаться достижимой и после него.
/datum/unit_test/bfl_meltdown_after_scram
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_meltdown_after_scram/Run()
	var/list/setup = setup_bfl_emitter(BFL_MODE_5, 100 MEGA JOULES)
	var/obj/machinery/power/bfl/emitter/emitter = setup[1]
	var/datum/powernet/network = setup[2]

	// Доводим ядро до аварийного сброса.
	var/ticks = 0
	while(emitter.state == BFL_STATE_ONLINE && ticks < 500)
		network.load = 0
		network.avail = 100 MEGA JOULES
		emitter.process(2)
		ticks++
	TEST_ASSERT_EQUAL(emitter.state, BFL_STATE_SCRAM, "Ожидался аварийный сброс.")

	// Тепло осталось в ядре — доводим его до критической температуры.
	emitter.core_heat = BFL_CORE_HEAT_CAPACITY * (BFL_TEMP_MELTDOWN - BFL_TEMP_BASE)
	emitter.core_temperature = BFL_TEMP_MELTDOWN
	emitter.process(2)

	TEST_ASSERT_EQUAL(emitter.state, BFL_STATE_BROKEN, "После аварийного сброса катастрофа всё ещё должна быть достижима.")

	return TRUE

// ---------------------------------------------------------------------------
// Охлаждение контуром
// ---------------------------------------------------------------------------

/datum/unit_test/bfl_coolant_cooling
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_coolant_cooling/Run()
	var/list/setup = setup_bfl_emitter(BFL_MODE_1, 100 MEGA JOULES)
	var/obj/machinery/power/bfl/emitter/emitter = setup[1]
	var/list/port_setup = setup_bfl_coolant_port(moles = 8, gas_type = /datum/gas/nitrogen, temperature = 300)
	var/obj/machinery/atmospherics/components/unary/bfl_coolant_port/port = port_setup[1]

	emitter.link_coolant_port(port, null)

	TEST_ASSERT(emitter.get_coolant_port() == port, "Порт должен быть связан с ядром.")
	TEST_ASSERT(port.get_core() == emitter, "Порт должен знать своё ядро.")

	// Контур из азота холоднее ядра — значит он способен отводить тепло.
	emitter.core_temperature = 600
	var/cooling = emitter.get_cooling_capacity()
	TEST_ASSERT(cooling > 0, "Холодный контур должен отводить тепло.")

	// Порт обязан считать ёмкость ровно так же, как это делает газовая смесь.
	var/datum/gas_mixture/reference_mix = new(200)
	reference_mix.moles[/datum/gas/nitrogen] = 8
	TEST_ASSERT_EQUAL(port.get_loop_heat_capacity(), reference_mix.heat_capacity(), "Теплоёмкость контура неверна.")
	qdel(reference_mix)

	// Если контур горячее ядра, отвода тепла быть не должно.
	port.parents[1].air.temperature = 900
	TEST_ASSERT_EQUAL(emitter.get_cooling_capacity(), 0, "Горячий контур не должен отводить тепло.")

	// Пустой контур не охлаждает вовсе.
	port.parents[1].air.moles = list()
	TEST_ASSERT_EQUAL(emitter.get_cooling_capacity(), 0, "Пустой контур не должен отводить тепло.")

	return TRUE

/// Гипер-ноблиум должен давать контуру заметно большую теплоёмкость, чем азот.
/datum/unit_test/bfl_coolant_gas_comparison
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_coolant_gas_comparison/Run()
	var/list/nitrogen = setup_bfl_coolant_port(moles = 8, gas_type = /datum/gas/nitrogen)
	var/list/hypernoblium = setup_bfl_coolant_port(moles = 8, gas_type = /datum/gas/hypernoblium)

	var/nitrogen_capacity = nitrogen[1].get_loop_heat_capacity()
	var/hypernoblium_capacity = hypernoblium[1].get_loop_heat_capacity()

	TEST_ASSERT(hypernoblium_capacity > nitrogen_capacity, "Гипер-ноблиум должен давать большую теплоёмкость контура, чем азот.")

	return TRUE

// ---------------------------------------------------------------------------
// Начисление кредитов
// ---------------------------------------------------------------------------

/datum/unit_test/bfl_credits_payment
	priority = TEST_DEFAULT
	test_flags = UNIT_TEST_MAP_TEST

/datum/unit_test/bfl_credits_payment/Run()
	var/datum/bank_account/department/account = SSeconomy.get_dep_account(ACCOUNT_CAR)
	TEST_ASSERT_NOTNULL(account, "Счёт отдела снабжения должен существовать.")
	var/starting_balance = account.account_balance

	var/obj/machinery/power/bfl/emitter/emitter = allocate(/obj/machinery/power/bfl/emitter)
	emitter.pay_credits(100)

	TEST_ASSERT_EQUAL(account.account_balance, starting_balance + 100, "Кредиты должны поступить на счёт снабжения.")

	return TRUE
