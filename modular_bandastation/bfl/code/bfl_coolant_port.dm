/// BFL — порт охлаждения.
///
/// Обеспечивает теплоотвод от ядра установки в замкнутый контур.
///
/// Физика: ядро и газ контура обмениваются теплом по теплопроводности.
/// Мощность отвода пропорциональна разнице температур и теплоёмкости контура,
/// то есть зависит от удельной теплоёмкости газа и от объёма контура.
/// Контур, подключённый к атмосфере станции, отводит тепло практически без
/// ограничений; загерметизированный маленький контур насыщается и перестаёт
/// охлаждать — тепло копится в ядре.
///
/// Связь с ядром односторонняя: ядро владеет портом и само устанавливает
/// ссылку через [proc/set_core_ref]. Поэтому порт не зависит от типа ядра.

/obj/machinery/atmospherics/components/unary/bfl_coolant_port
	name = "BFL Coolant Port"
	desc = "Теплообменник фокусирующего лазера. Отводит тепло ядра установки в замкнутый контур с теплоносителем. Чем выше удельная теплоёмкость газа в контуре и больше его объём — тем эффективнее охлаждение."
	// TODO: временный спрайт, будет заменён собственным.
	icon = 'icons/obj/machines/atmospherics/unary_devices.dmi'
	icon_state = "he0"
	plane = GAME_PLANE
	density = TRUE
	max_integrity = 300
	armor_type = /datum/armor/unary_thermomachine
	layer = OBJ_LAYER
	move_resist = MOVE_RESIST_DEFAULT
	vent_movement = NONE
	pipe_flags = PIPING_ONE_PER_TURF
	construction_type = /obj/item/pipe/directional/bfl_coolant_port
	circuit = /obj/item/circuitboard/machine/bfl_coolant_port

	/// Слабая ссылка на ядро BFL, которое обслуживает этот порт.
	var/datum/weakref/core_ref
	/// Последняя измеренная мощность отвода тепла (Вт). Только для отображения.
	var/last_cooling_power = 0

/obj/item/pipe/directional/bfl_coolant_port
	name = "BFL coolant port fitting"
	icon_state_preview = "heunary"
	pipe_type = /obj/machinery/atmospherics/components/unary/bfl_coolant_port
	custom_materials = list(/obj/item/stack/sheet/iron = SHEET_MATERIAL_AMOUNT, /obj/item/stack/sheet/plasteel = SHEET_MATERIAL_AMOUNT)

/obj/machinery/atmospherics/components/unary/bfl_coolant_port/Initialize(mapload)
	. = ..()
	update_appearance(UPDATE_ICON)

/obj/machinery/atmospherics/components/unary/bfl_coolant_port/on_construction(mob/user, obj_color, set_layer)
	var/obj/item/circuitboard/machine/bfl_coolant_port/board = circuit
	if(board)
		piping_layer = board.pipe_layer
		set_layer = piping_layer

	..()

	if(check_pipe_on_turf())
		set_anchored(FALSE)
		set_panel_open(TRUE)
		balloon_alert(user, "на тайле уже есть труба!")

/obj/machinery/atmospherics/components/unary/bfl_coolant_port/Destroy(force)
	core_ref = null
	return ..()

// ---------------------------------------------------------------------------
// Теплообмен
// ---------------------------------------------------------------------------

/// Теплоёмкость газа в контуре (Дж/К). Суммарная по всей трубной сети,
/// к которой подключён порт.
/obj/machinery/atmospherics/components/unary/bfl_coolant_port/proc/get_loop_heat_capacity()
	var/datum/pipeline/pipe = parents[1]
	if(!pipe?.air)
		return 0
	return pipe.air.heat_capacity()

/// Температура газа в контуре (К).
/obj/machinery/atmospherics/components/unary/bfl_coolant_port/proc/get_loop_temperature()
	var/datum/pipeline/pipe = parents[1]
	if(!pipe?.air)
		return 0
	return pipe.air.temperature

/// Мощность, которую контур способен отвести от ядра при заданной
/// температуре ядра (Вт).
/obj/machinery/atmospherics/components/unary/bfl_coolant_port/proc/get_cooling_capacity(core_temperature)
	var/loop_capacity = get_loop_heat_capacity()
	if(loop_capacity <= 0)
		last_cooling_power = 0
		return 0
	var/delta_T = core_temperature - get_loop_temperature()
	if(delta_T <= 0)
		last_cooling_power = 0
		return 0
	// Q = C_контура * ΔT * скорость_релаксации  [Вт]
	var/power = loop_capacity * delta_T * BFL_COOLANT_RATE
	power = min(power, BFL_COOLANT_MAX_TRANSFER)
	last_cooling_power = power
	return power

/// Передаёт энергию из ядра в газ контура.
/obj/machinery/atmospherics/components/unary/bfl_coolant_port/proc/transfer_heat(energy)
	if(energy <= 0)
		return
	var/datum/pipeline/pipe = parents[1]
	if(!pipe?.air)
		return
	var/capacity = pipe.air.heat_capacity()
	if(capacity <= 0)
		return
	pipe.air.temperature += energy / capacity
	// Просим конвейер пересчитать распределение газа и температуры по сети.
	pipe.update = TRUE

// ---------------------------------------------------------------------------
// Связь с ядром
// ---------------------------------------------------------------------------

/// Устанавливает ссылку на обслуживаемое ядро. Вызывается ядром.
/// Передаётся [datum/weakref], чтобы порт не зависел от типа ядра.
/obj/machinery/atmospherics/components/unary/bfl_coolant_port/proc/set_core_ref(datum/weakref/ref)
	core_ref = ref

/// Ядро, обслуживаемое этим портом.
/obj/machinery/atmospherics/components/unary/bfl_coolant_port/proc/get_core() as /atom
	var/atom/core = core_ref?.resolve()
	if(QDELETED(core))
		return null
	return core

// ---------------------------------------------------------------------------
// Взаимодействие
// ---------------------------------------------------------------------------

/// Проверяет, не занят ли тайл другой трубой того же слоя.
/obj/machinery/atmospherics/components/unary/bfl_coolant_port/proc/check_pipe_on_turf()
	for(var/obj/machinery/atmospherics/device in get_turf(src))
		if(device == src)
			continue
		if(device.piping_layer == piping_layer)
			return TRUE
	return FALSE

/obj/machinery/atmospherics/components/unary/bfl_coolant_port/multitool_act(mob/living/user, obj/item/multitool/multitool)
	. = ..()
	if(. == ITEM_INTERACT_SUCCESS)
		return
	// Сохраняем порт в буфере мультитула, чтобы потом связать его с ядром.
	multitool.set_buffer(src)
	to_chat(user, span_notice("Вы сохранили данные порта охлаждения в буфере [multitool]."))
	return ITEM_INTERACT_SUCCESS

/obj/machinery/atmospherics/components/unary/bfl_coolant_port/examine(mob/user)
	. = ..()
	var/atom/core = get_core()
	if(core)
		. += span_info("Подключён к ядру установки на [core.loc].")
	else
		. += span_warning("Не подключён к ядру установки.")
	. += span_info("Теплоёмкость контура: [round(get_loop_heat_capacity())] Дж/К, температура газа: [round(get_loop_temperature())] К.")
	if(last_cooling_power > 0)
		. += span_info("Текущий отвод тепла: [round(last_cooling_power / 1000)] кВт.")

/obj/machinery/atmospherics/components/unary/bfl_coolant_port/add_context(atom/source, list/context, obj/item/held_item, mob/user)
	. = ..()
	context[SCREENTIP_CONTEXT_CTRL_LMB] = "Связать с ядром"
	if(held_item)
		switch(held_item.tool_behaviour)
			if(TOOL_MULTITOOL)
				context[SCREENTIP_CONTEXT_LMB] = "Сохранить в буфер мультитула"
			if(TOOL_WRENCH)
				context[SCREENTIP_CONTEXT_LMB] = "[anchored ? "От" : "За"]анкорить"
	return CONTEXTUAL_SCREENTIP_SET
