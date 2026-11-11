/// Платы, чертежи и узел техвеба для установки BFL.

/obj/item/circuitboard/machine/bfl_emitter
	name = "Beam Freight Laser Board"
	desc = "Плата управления фокусирующим лазером. Позволяет собрать ядро установки по продаже электроэнергии Центральному командованию."
	greyscale_colors = CIRCUIT_COLOR_ENGINEERING
	build_path = /obj/machinery/power/bfl/emitter
	req_components = list(
		/datum/stock_part/capacitor/tier2 = 2,
		/datum/stock_part/servo/tier2 = 2,
		/datum/stock_part/micro_laser/tier2 = 2,
		/obj/item/stack/sheet/iron = 10,
		/obj/item/stack/cable_coil = 2,
	)

/datum/design/board/bfl_emitter
	name = "Beam Freight Laser Board"
	desc = "Чертёж ядра фокусирующего лазера. Используется для сборки установки по продаже электроэнергии Центральному командованию."
	build_path = /obj/item/circuitboard/machine/bfl_emitter
	// Ядро занимает 3x3 тайла, поэтому для списка разработки используем
	// отдельный репрезентативный спрайт 32x32.
	research_icon = 'icons/obj/machines/engine/other.dmi'
	research_icon_state = "rtg"
	category = list(
		RND_CATEGORY_MACHINE + RND_SUBCATEGORY_MACHINE_ENGINEERING
	)
	departmental_flags = DEPARTMENT_BITFLAG_ENGINEERING

// ---------------------------------------------------------------------------
// Порт охлаждения
// ---------------------------------------------------------------------------

/obj/item/circuitboard/machine/bfl_coolant_port
	name = "BFL Coolant Port"
	desc = "Плата теплообменника фокусирующего лазера. Позволяет собрать порт охлаждения для контура установки."
	greyscale_colors = CIRCUIT_COLOR_ENGINEERING
	build_path = /obj/machinery/atmospherics/components/unary/bfl_coolant_port
	var/pipe_layer = PIPING_LAYER_DEFAULT
	req_components = list(
		/datum/stock_part/matter_bin = 1,
		/datum/stock_part/amplifier = 1,
		/obj/item/stack/cable_coil = 1,
		/obj/item/stack/sheet/glass = 1)

/obj/item/circuitboard/machine/bfl_coolant_port/multitool_act(mob/living/user, obj/item/multitool/multitool)
	. = ..()
	pipe_layer = (pipe_layer >= PIPING_LAYER_MAX) ? PIPING_LAYER_MIN : (pipe_layer + 1)
	to_chat(user, span_notice("Вы переключаете плату на слой [pipe_layer]."))

/obj/item/circuitboard/machine/bfl_coolant_port/examine()
	. = ..()
	. += span_notice("Плата настроена на слой [pipe_layer].")

/datum/design/board/bfl_coolant_port
	name = "BFL Coolant Port Board"
	desc = "Чертёж порта охлаждения фокусирующего лазера. Используется для сборки теплообменника контура установки."
	build_path = /obj/item/circuitboard/machine/bfl_coolant_port
	category = list(
		RND_CATEGORY_MACHINE + RND_SUBCATEGORY_MACHINE_ATMOS
	)
	departmental_flags = DEPARTMENT_BITFLAG_ENGINEERING

/datum/techweb_node/bfl
	display_name = "Фокусирующий лазер"
	description = "Станционная установка по продаже избытков энергии Центральному командованию. Требует мощной сети и замкнутого контура газового охлаждения."
	prerequisite_nodes = list(/datum/techweb_node/energy_manipulation)
	unlocked_designs = list(
		/datum/design/board/bfl_emitter,
		/datum/design/board/bfl_coolant_port,
	)
	research_costs = list(TECHWEB_POINT_TYPE_GENERIC = TECHWEB_TIER_1_POINTS)
	announce_channels = list(RADIO_CHANNEL_ENGINEERING)
