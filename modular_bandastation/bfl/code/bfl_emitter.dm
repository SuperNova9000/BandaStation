/// BFL — ядро установки.
///
/// Тянет мощность из энергосети, конвертирует часть её в тепло в ядре,
/// а оставшуюся продаёт Центральному командованию за кредиты.
/// Требует газового охлаждения: без работающего контура перегревается
/// и в итоге приводит к катастрофе.

/// Сигналы модуля BFL.
/// Отправляются объектом /obj/machinery/power/bfl/emitter.

/// Смена состояния установки. (новое_состояние, старый_состояние)
#define COMSIG_BFL_STATE_CHANGED "bfl_state_changed"
/// Смена рабочего режима. (новый_режим, старый_режим)
#define COMSIG_BFL_MODE_CHANGED "bfl_mode_changed"
/// Накопленная энергия передана в сеть и оплачена. (энергия_в_джоулях, кредиты)
#define COMSIG_BFL_TRANSFERRED "bfl_transferred"
/// Установка входит в аварийное состояние. (уровень_критичности)
#define COMSIG_BFL_CRITICAL "bfl_critical"

/obj/machinery/power/bfl/emitter
	name = "Beam Freight Laser"
	desc = "Крупнейший лазер фокусирующего типа на станции. Отбирает мощность из энергосети и передаёт её на орбитальный ретранслятор Центрального командования, получая за это кредиты. Требует непрерывного газового охлаждения контура."
	// TODO: временный спрайт. Будет заменён собственным при подготовке ассетов.
	icon = 'icons/obj/fluff/3x3.dmi'
	icon_state = "huge_engine"
	base_icon_state = "huge_engine"
	bound_width = 96
	bound_height = 96
	pixel_x = -96
	pixel_y = -96
	appearance_flags = LONG_GLIDE
	density = TRUE
	anchored = TRUE
	layer = BELOW_OBJ_LAYER
	max_integrity = 500
	armor_type = /datum/armor/obj_machinery
	circuit = /obj/item/circuitboard/machine/bfl_emitter

	/// Текущее состояние установки, см. BFL_STATE_*.
	var/state = BFL_STATE_OFFLINE
	/// Текущий рабочий режим, см. BFL_MODE_*.
	var/mode = BFL_MODE_OFF

	/// Накопленное в ядре тепло (Дж).
	var/core_heat = 0
	/// Температура ядра (К).
	var/core_temperature = BFL_TEMP_BASE
	/// Накопленные повреждения от перегрева.
	var/damage = 0

	/// Всего энергии передано за раунд (Дж).
	var/total_energy_transmitted = 0
	/// Всего заработано кредитов за раунд.
	var/total_credits_earned = 0
	/// Накопленные, но ещё не выплаченные кредиты.
	var/pending_credits = 0

	/// Слабая ссылка на порт охлаждения, через который ядро сбрасывает тепло.
	var/datum/weakref/coolant_port_ref
	/// Слабая ссылка на консоль управления.
	var/datum/weakref/control_ref

	/// Момент времени, когда установка дошла до режима.
	var/state_started_at = 0
	/// Счётчик тиков подряд идущей просадки сети.
	var/grid_sag_ticks = 0
	/// Выдавалось ли уже предупреждение об отсутствии подключения к сети.
	var/unconnected_warned = FALSE
	/// Прошлый режим, восстанавливаемый после сброса.
	var/last_active_mode = BFL_MODE_OFF

	/// Кулдаун на оповещение о перегреве.
	COOLDOWN_DECLARE(overheat_warning)

/obj/machinery/power/bfl/emitter/Initialize(mapload)
	. = ..()
	core_temperature = BFL_TEMP_BASE
	connect_to_network()
	register_context()
	update_appearance(UPDATE_ICON)

/obj/machinery/power/bfl/emitter/Destroy(force)
	coolant_port_ref = null
	control_ref = null
	return ..()

/obj/machinery/power/bfl/emitter/post_machine_initialize()
	. = ..()
	// Разъём сети нужно искать после того, как машина встала на место.
	connect_to_network()

// ---------------------------------------------------------------------------
// Основной цикл
// ---------------------------------------------------------------------------

/obj/machinery/power/bfl/emitter/process(seconds_per_tick)
	if(machine_stat & (BROKEN | NOPOWER))
		return

	// Без подключения к энергосети установка работает вхолостую.
	if(!powernet)
		warn_unconnected()
		return

	switch(state)
		if(BFL_STATE_WARMUP)
			process_warmup(seconds_per_tick)
		if(BFL_STATE_ONLINE)
			process_online(seconds_per_tick)
		if(BFL_STATE_SCRAM)
			process_cooldown(seconds_per_tick)

	// Проверка температуры идёт во всех состояниях: после аварийного сброса
	// тепло остаётся в ядре и всё ещё может довести до катастрофы.
	check_temperature()

/// Однократное предупреждение о том, что установка не подключена к сети.
/obj/machinery/power/bfl/emitter/proc/warn_unconnected()
	if(unconnected_warned)
		return
	unconnected_warned = TRUE
	visible_message(span_warning("[src] не подключена к энергосети. Кабель должен лежать на тайле, где установлен нижний левый угол корпуса."))
	investigate_log("не подключена к энергосети.", INVESTIGATE_ENGINE)

/// Прогрев ядра перед выходом на рабочий режим.
/obj/machinery/power/bfl/emitter/proc/process_warmup(seconds_per_tick)
	if(world.time - state_started_at < BFL_WARMUP_TIME)
		return
	set_state(BFL_STATE_ONLINE)
	investigate_log("вышел на рабочий режим [mode].", INVESTIGATE_ENGINE)

/// Охлаждение после аварийного сброса. Тепло продолжает уходить, но пучок не горит.
/obj/machinery/power/bfl/emitter/proc/process_cooldown(seconds_per_tick)
	cool_core(seconds_per_tick)
	if(world.time - state_started_at < BFL_COOLDOWN_TIME)
		return
	set_state(BFL_STATE_OFFLINE)
	mode = BFL_MODE_OFF
	investigate_log("остыл и перешёл в дежурный режим.", INVESTIGATE_ENGINE)

/// Рабочий цикл: отбор мощности, выработка тепла, начисление кредитов.
/obj/machinery/power/bfl/emitter/proc/process_online(seconds_per_tick)
	var/requested_power = get_mode_power(mode)
	if(requested_power <= 0)
		return

	// Сколько энергии мы хотим взять за этот тик.
	var/requested_energy = power_to_energy(requested_power)

	// Сколько свободной мощности есть в сети. surplus() = avail - load.
	var/available_energy = surplus()

	// Доля от излишка, которую установка готова забрать. Ограничение нужно,
	// чтобы BFL не вырубил APC всей станции.
	var/allowed_energy = available_energy * BFL_MAX_GRID_SHARE
	var/taken_energy = min(requested_energy, allowed_energy)

	if(taken_energy > 0)
		add_load(taken_energy)

	// Проверка просадки сети: если сеть не выдаёт даже 90% запрошенного —
	// снижаем режим, чтобы не уронить станцию.
	if(taken_energy < requested_energy * BFL_GRID_SAG_THRESHOLD)
		grid_sag_ticks++
		if(grid_sag_ticks >= BFL_GRID_SAG_TICKS)
			grid_sag_ticks = 0
			if(mode > BFL_MODE_MIN)
				set_mode(mode - 1)
				visible_message(span_warning("[src] снижает режим из-за просадки сети."))
				investigate_log("снизил режим до [mode] из-за просадки сети.", INVESTIGATE_ENGINE)
	else
		grid_sag_ticks = 0

	// Энергия, ушедшая на ретранслятор, и тепло, осевшее в ядре.
	var/transmitted_energy = taken_energy * get_efficiency()
	var/heat_energy = taken_energy - transmitted_energy

	core_heat += heat_energy
	core_temperature = BFL_TEMP_BASE + core_heat / BFL_CORE_HEAT_CAPACITY

	total_energy_transmitted += transmitted_energy
	award_credits(transmitted_energy)

	// Отвод тепла контуром.
	cool_core(seconds_per_tick)

/// Проверка температурных порогов: предупреждение, SCRAM, катастрофа.
/obj/machinery/power/bfl/emitter/proc/check_temperature()
	if(core_temperature >= BFL_TEMP_MELTDOWN)
		trigger_meltdown()
		return

	if(core_temperature >= BFL_TEMP_CRITICAL)
		damage = min(damage + BFL_DAMAGE_PER_TICK, BFL_DAMAGE_MAX)
		if(!COOLDOWN_FINISHED(src, overheat_warning))
			COOLDOWN_START(src, overheat_warning, 10 SECONDS)
			visible_message(span_danger("[src] перегревается! Температура ядра [round(core_temperature)] K."))
			investigate_log("перегрев, температура ядра [round(core_temperature)] K.", INVESTIGATE_ENGINE)
			SEND_SIGNAL(src, COMSIG_BFL_CRITICAL, 2)
		// Аварийный сброс гасит пучок, но не отменяет накопление тепла.
		if(state == BFL_STATE_ONLINE)
			emergency_scram()
		return

	if(core_temperature >= BFL_TEMP_WARNING)
		if(!COOLDOWN_FINISHED(src, overheat_warning))
			COOLDOWN_START(src, overheat_warning, 30 SECONDS)
			visible_message(span_warning("[src] нагревается. Температура ядра [round(core_temperature)] K."))
			investigate_log("рост температуры ядра, [round(core_temperature)] K.", INVESTIGATE_ENGINE)
			SEND_SIGNAL(src, COMSIG_BFL_CRITICAL, 1)
		return

	// На охлаждении повреждения медленно восстанавливаются.
	if(damage > 0)
		damage = max(damage - 0.1, 0)

// ---------------------------------------------------------------------------
// Деньги
// ---------------------------------------------------------------------------

/// Начисляет кредиты за переданную энергию.
/obj/machinery/power/bfl/emitter/proc/award_credits(transmitted_energy)
	if(transmitted_energy <= 0)
		return
	var/megajoules = transmitted_energy / (1 MEGA JOULES)
	pending_credits += megajoules * get_tariff()
	total_credits_earned += megajoules * get_tariff()
	if(pending_credits < 1)
		return
	var/payout = floor(pending_credits)
	pending_credits -= payout
	pay_credits(payout)
	SEND_SIGNAL(src, COMSIG_BFL_TRANSFERRED, transmitted_energy, payout)

/// Переводит кредиты на счёт отдела снабжения.
/obj/machinery/power/bfl/emitter/proc/pay_credits(amount)
	if(amount <= 0)
		return
	var/datum/bank_account/department/account = SSeconomy?.get_dep_account(ACCOUNT_CAR)
	if(!account)
		return
	account.adjust_money(amount, "BFL: продажа энергии на орбитальный ретранслятор")

/// Текущий тариф с учётом деградации после насыщения рынка.
/obj/machinery/power/bfl/emitter/proc/get_tariff()
	if(total_energy_transmitted < BFL_TARIFF_DECAY_THRESHOLD)
		return get_base_tariff(mode)
	return get_base_tariff(mode) * BFL_TARIFF_DECAY_FACTOR

// ---------------------------------------------------------------------------
// Охлаждение
// ---------------------------------------------------------------------------

/// Отдаёт часть накопленного тепла в контур охлаждения.
/obj/machinery/power/bfl/emitter/proc/cool_core(seconds_per_tick)
	var/obj/machinery/atmospherics/components/unary/bfl_coolant_port/port = get_coolant_port()
	if(!port)
		return
	var/cooling = min(get_cooling_capacity() * seconds_per_tick, core_heat)
	if(cooling <= 0)
		return
	core_heat -= cooling
	core_temperature = BFL_TEMP_BASE + core_heat / BFL_CORE_HEAT_CAPACITY
	port.transfer_heat(cooling)

/// Мощность отвода тепла контуром (Вт).
/obj/machinery/power/bfl/emitter/proc/get_cooling_capacity()
	var/obj/machinery/atmospherics/components/unary/bfl_coolant_port/port = get_coolant_port()
	if(!port)
		return 0
	return port.get_cooling_capacity(core_temperature)

/// Порт охлаждения, связанный с этим ядром.
/obj/machinery/power/bfl/emitter/proc/get_coolant_port() as /obj/machinery/atmospherics/components/unary/bfl_coolant_port
	var/obj/machinery/atmospherics/components/unary/bfl_coolant_port/port = coolant_port_ref?.resolve()
	if(QDELETED(port))
		return null
	return port

// ---------------------------------------------------------------------------
// Параметры режима
// ---------------------------------------------------------------------------

/// Запрошенная мощность режима (Вт).
/obj/machinery/power/bfl/emitter/proc/get_mode_power(mode_index)
	switch(mode_index)
		if(BFL_MODE_1)
			return BFL_MODE_POWER_1
		if(BFL_MODE_2)
			return BFL_MODE_POWER_2
		if(BFL_MODE_3)
			return BFL_MODE_POWER_3
		if(BFL_MODE_4)
			return BFL_MODE_POWER_4
		if(BFL_MODE_5)
			return BFL_MODE_POWER_5
	return 0

/// КПД режима с учётом повреждений.
/obj/machinery/power/bfl/emitter/proc/get_efficiency()
	var/efficiency = 0
	switch(mode)
		if(BFL_MODE_1)
			efficiency = BFL_MODE_EFFICIENCY_1
		if(BFL_MODE_2)
			efficiency = BFL_MODE_EFFICIENCY_2
		if(BFL_MODE_3)
			efficiency = BFL_MODE_EFFICIENCY_3
		if(BFL_MODE_4)
			efficiency = BFL_MODE_EFFICIENCY_4
		if(BFL_MODE_5)
			efficiency = BFL_MODE_EFFICIENCY_5
	var/penalty = damage * BFL_DAMAGE_EFFICIENCY_PENALTY
	return clamp(efficiency - penalty, 0.05, 1)

/// Базовый тариф режима (кредитов за мегаджоуль).
/obj/machinery/power/bfl/emitter/proc/get_base_tariff(mode_index)
	switch(mode_index)
		if(BFL_MODE_1)
			return BFL_TARIFF_1
		if(BFL_MODE_2)
			return BFL_TARIFF_2
		if(BFL_MODE_3)
			return BFL_TARIFF_3
		if(BFL_MODE_4)
			return BFL_TARIFF_4
		if(BFL_MODE_5)
			return BFL_TARIFF_5
	return 0

// ---------------------------------------------------------------------------
// Управление
// ---------------------------------------------------------------------------

/// Переводит установку в рабочий режим с указанным режимом.
/obj/machinery/power/bfl/emitter/proc/set_mode(new_mode)
	if(new_mode < BFL_MODE_MIN || new_mode > BFL_MODE_MAX)
		return FALSE
	if(machine_stat & (BROKEN | NOPOWER))
		return FALSE
	if(state == BFL_STATE_SCRAM)
		return FALSE
	var/old_mode = mode
	mode = new_mode
	last_active_mode = new_mode
	if(state == BFL_STATE_OFFLINE)
		set_state(BFL_STATE_WARMUP)
		state_started_at = world.time
	SEND_SIGNAL(src, COMSIG_BFL_MODE_CHANGED, new_mode, old_mode)
	return TRUE

/// Аварийный сброс: пучок гаснет, но тепло остаётся в ядре.
/obj/machinery/power/bfl/emitter/proc/emergency_scram()
	if(state == BFL_STATE_SCRAM)
		return
	last_active_mode = mode
	mode = BFL_MODE_OFF
	set_state(BFL_STATE_SCRAM)
	state_started_at = world.time
	visible_message(span_danger("[src] аварийно остановлен! Тепло продолжает накапливаться."))
	investigate_log("аварийный сброс, температура ядра [round(core_temperature)] K.", INVESTIGATE_ENGINE)
	SEND_SIGNAL(src, COMSIG_BFL_STATE_CHANGED, BFL_STATE_SCRAM, BFL_STATE_ONLINE)

/// Смена состояния установки.
/obj/machinery/power/bfl/emitter/proc/set_state(new_state)
	if(state == new_state)
		return
	var/old_state = state
	state = new_state
	update_appearance(UPDATE_ICON)
	SEND_SIGNAL(src, COMSIG_BFL_STATE_CHANGED, new_state, old_state)

/// Катастрофа. Взрыв и станционный ЭМИ.
/obj/machinery/power/bfl/emitter/proc/trigger_meltdown()
	if(state == BFL_STATE_BROKEN)
		return
	set_state(BFL_STATE_BROKEN)
	mode = BFL_MODE_OFF
	set_machine_stat(machine_stat | BROKEN)
	investigate_log("перегрев до катастрофической температуры.", INVESTIGATE_ENGINE)
	SEND_SIGNAL(src, COMSIG_BFL_CRITICAL, 3)
	// Дальнейшая логика катастрофы — в bfl_disaster.dm
	meltdown()

/// Катастрофа — переопределяется в bfl_disaster.dm.
/obj/machinery/power/bfl/emitter/proc/meltdown()
	return

// ---------------------------------------------------------------------------
// Взаимодействие
// ---------------------------------------------------------------------------

/obj/machinery/power/bfl/emitter/multitool_act(mob/living/user, obj/item/tool)
	. = ..()
	if(. == ITEM_INTERACT_SUCCESS)
		return
	var/obj/item/multitool/multitool = tool
	// Если в буфере мультитула лежит порт охлаждения — связываем его с ядром.
	if(istype(multitool.buffer, /obj/machinery/atmospherics/components/unary/bfl_coolant_port))
		link_coolant_port(multitool.buffer, user)
		return ITEM_INTERACT_SUCCESS
	// Иначе — прямое управление режимом. Основное управление — с консоли.
	cycle_mode(user)

/// Связывает порт охлаждения с этим ядром.
/obj/machinery/power/bfl/emitter/proc/link_coolant_port(obj/machinery/atmospherics/components/unary/bfl_coolant_port/port, mob/user)
	var/obj/machinery/atmospherics/components/unary/bfl_coolant_port/previous_port = get_coolant_port()
	if(previous_port == port)
		return
	if(previous_port)
		previous_port.set_core_ref(null)
	port.set_core_ref(WEAKREF(src))
	coolant_port_ref = WEAKREF(port)
	if(user)
		to_chat(user, span_notice("Вы связали порт охлаждения с [src]."))
		playsound(get_turf(user), 'sound/machines/click.ogg', 10, TRUE)

/obj/machinery/power/bfl/emitter/proc/cycle_mode(mob/user)
	if(state == BFL_STATE_SCRAM)
		balloon_alert(user, "установка на аварийном сбросе!")
		return
	if(state == BFL_STATE_BROKEN)
		balloon_alert(user, "установка разрушена!")
		return
	var/new_mode = mode + 1
	if(new_mode > BFL_MODE_MAX)
		new_mode = BFL_MODE_MIN
	set_mode(new_mode)
	to_chat(user, span_notice("Режим BFL: [new_mode]."))

/obj/machinery/power/bfl/emitter/examine(mob/user)
	. = ..()
	. += span_info("Состояние: [get_state_text()].")
	. += span_info("Режим: [mode] из [BFL_MODE_MAX], КПД [round(get_efficiency() * 100)]%.")
	. += span_info("Температура ядра: [round(core_temperature)] K.")
	. += span_info("Передано энергии: [format_energy(total_energy_transmitted)], заработано: [total_credits_earned] кр.")
	var/port = get_coolant_port()
	if(port)
		. += span_info("Контур охлаждения подключён.")
	else
		. += span_warning("Контур охлаждения не подключён — установка перегреется.")

/// Текстовое описание состояния.
/obj/machinery/power/bfl/emitter/proc/get_state_text()
	switch(state)
		if(BFL_STATE_OFFLINE)
			return "дежурный режим"
		if(BFL_STATE_WARMUP)
			return "выход на режим"
		if(BFL_STATE_ONLINE)
			return "работает"
		if(BFL_STATE_SCRAM)
			return "аварийный сброс"
		if(BFL_STATE_BROKEN)
			return "разрушена"
	return "неизвестно"

/obj/machinery/power/bfl/emitter/add_context(atom/source, list/context, obj/item/held_item, mob/user)
	. = ..()
	context[SCREENTIP_CONTEXT_CTRL_LMB] = "Следующий режим"
	if(held_item)
		switch(held_item.tool_behaviour)
			if(TOOL_MULTITOOL)
				context[SCREENTIP_CONTEXT_LMB] = "Переключить режим"
			if(TOOL_WRENCH)
				context[SCREENTIP_CONTEXT_LMB] = "[anchored ? "От" : "За"]анкорить"
	return CONTEXTUAL_SCREENTIP_SET

/// Форматирование энергии для показа в чате.
/obj/machinery/power/bfl/emitter/proc/format_energy(joules)
	if(joules >= (1 MEGA JOULES))
		return "[round(joules / (1 MEGA JOULES), 0.1)] МДж"
	return "[round(joules)] Дж"
