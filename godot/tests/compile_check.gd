extends SceneTree
## Fast syntax check: loads every GDScript in the project and reports the ones that fail to compile.
## Takes a few seconds instead of a full boot.
##   godot --headless --path godot --script res://tests/compile_check.gd


## _initialize, not _init: the autoload names (Mission, Api, Sfx) are only known once the tree is set up.
func _initialize() -> void:
	var paths := _scan("res://scripts") + _scan("res://tests")
	var bad := PackedStringArray()
	for p in paths:
		var s := load(p) as GDScript
		if s == null or not s.can_instantiate():
			bad.append(p)
	print("compile_check: %d scripts, %d failed%s" % [paths.size(), bad.size(), (": " + ", ".join(bad)) if not bad.is_empty() else ""])
	quit(1 if not bad.is_empty() else 0)


func _scan(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		out.append_array(_scan(dir.path_join(sub)))
	return out
