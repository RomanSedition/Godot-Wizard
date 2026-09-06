@tool
class_name WizardModel
extends RefCounted

## Editor-side persistent store for the Wizard checklist. Singleton idiom
## mirrors McpToolRegistry (static _instance, instance fields/signals so
## multiple consumers — the dock UI, the watch manager, the MCP tool
## handlers — can all react to the same state). Owned by plugin.gd;
## state resets whenever the plugin reloads.

const KIND_SCENE_SELECT := "scene-select"
const KIND_SCENE_RENAME := "scene-rename"
const KIND_RESOURCE_CREATE := "resource-create"
const KIND_MANUAL := "manual"
const VALID_KINDS := [KIND_SCENE_SELECT, KIND_SCENE_RENAME, KIND_RESOURCE_CREATE, KIND_MANUAL]

static var _instance: WizardModel = null

static func get_instance() -> WizardModel:
	return _instance

static func set_instance(inst: WizardModel) -> void:
	_instance = inst

## Each step: {label, search_text, kind, target_value, checked, manual_confirmed}
var steps: Array[Dictionary] = []

signal steps_changed

func set_steps(new_steps: Array[Dictionary]) -> void:
	steps = new_steps
	steps_changed.emit()

func get_steps_snapshot() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in steps:
		out.append(s.duplicate())
	return out

func mark_checked(index: int) -> void:
	if index >= 0 and index < steps.size() and not steps[index].get("checked", false):
		steps[index]["checked"] = true
		steps_changed.emit()

func set_manual_confirmed(index: int, value: bool) -> void:
	if index >= 0 and index < steps.size():
		steps[index]["manual_confirmed"] = value
		steps_changed.emit()

func clear_steps() -> void:
	steps = []
	steps_changed.emit()

## Un-ticks every step (keeping labels/search texts/kinds/target values
## intact) so the same checklist can be re-armed from step 1.
func reset_all_checked() -> void:
	for s in steps:
		s["checked"] = false
		s["manual_confirmed"] = false
	steps_changed.emit()
