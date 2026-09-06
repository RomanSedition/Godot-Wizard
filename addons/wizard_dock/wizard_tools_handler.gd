@tool
extends RefCounted

## MCP custom-tool handlers for the Wizard checklist. Registered by plugin.gd
## via McpToolRegistry as "wizard_set_steps" / "wizard_get_steps". Not a
## class_name (loaded by script_path per custom_tool_wrapper's contract) —
## keeps the global class table free of one more name to collide on.
##
## Dispatcher contract (dispatcher.gd _call_handler): every return MUST have
## a "data", "error", or "_deferred" top-level key, or the dispatcher reports
## a generic "malformed result" — a bare {"ok": true}/{"message": ...} does
## NOT satisfy it, learned the hard way.

func set_steps(params: Dictionary, _ctx) -> Dictionary:
	var labels: Array = params.get("labels", [])
	var search_texts: Array = params.get("search_texts", [])
	var kinds: Array = params.get("kinds", [])
	var target_values: Array = params.get("target_values", [])

	if labels.size() != search_texts.size():
		return {"error": "labels and search_texts must be the same length."}
	if not kinds.is_empty() and kinds.size() != labels.size():
		return {"error": "kinds, when provided, must be the same length as labels."}
	if not target_values.is_empty() and target_values.size() != labels.size():
		return {"error": "target_values, when provided, must be the same length as labels."}

	var steps: Array[Dictionary] = []
	for i in range(labels.size()):
		var kind: String = kinds[i] if i < kinds.size() else WizardModel.KIND_MANUAL
		if not WizardModel.VALID_KINDS.has(kind):
			return {"error": "Unknown kind '%s' at index %d. Must be one of: %s" % [kind, i, ", ".join(WizardModel.VALID_KINDS)]}
		steps.append({
			"label": labels[i],
			"search_text": search_texts[i],
			"kind": kind,
			"target_value": target_values[i] if i < target_values.size() else "",
			"checked": false,
			"manual_confirmed": false,
		})

	var model := WizardModel.get_instance()
	if model == null:
		return {"error": "Wizard model not ready (plugin still initializing?)."}
	model.set_steps(steps)

	var watcher := WizardWatcher.get_instance()
	if watcher != null:
		watcher.arm_all()

	return {"data": {"message": "Wizard checklist set with %d step(s)." % steps.size()}}


func get_steps(_params: Dictionary, _ctx) -> Dictionary:
	var model := WizardModel.get_instance()
	if model == null:
		return {"data": {"steps": []}}
	return {"data": {"steps": model.get_steps_snapshot()}}


## Boxes the given step's target on-screen (Scene Tree row, or a generic
## dock control matched by name/text/tooltip) with a pulsing orange overlay
## that auto-clears after a few seconds. Returns whether a target was found.
func highlight_step(params: Dictionary, _ctx) -> Dictionary:
	var index: int = params.get("index", -1)
	var model := WizardModel.get_instance()
	if model == null:
		return {"error": "Wizard model not ready (plugin still initializing?)."}
	var steps := model.get_steps_snapshot()
	if index < 0 or index >= steps.size():
		return {"error": "index out of range (checklist has %d step(s))." % steps.size()}

	var highlighter := WizardHighlighter.get_instance()
	if highlighter == null:
		return {"error": "Highlighter not ready."}
	var found := highlighter.highlight_step(steps[index])
	return {"data": {"highlighted": found, "label": steps[index].get("label", "")}}
