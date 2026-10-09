extends SceneTree

## VS-01 WP01 — writes nakama/tests/fixtures/rules_vectors.json from the
## GDScript rules (see godot/tests/vs01_wp01_rules_vectors.gd).
##
## Usage (from the repository root):
##   godot --headless --path godot --script "$PWD/nakama/scripts/generate_rules_vectors.gd" -- "$PWD/nakama/tests/fixtures/rules_vectors.json"

const RulesVectors := preload("res://tests/vs01_wp01_rules_vectors.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("usage: -- <output.json>")
		quit(2)
		return
	var file := FileAccess.open(args[0], FileAccess.WRITE)
	file.store_string(JSON.stringify(RulesVectors.build_vectors(), "  ", false) + "\n")
	file.close()
	print("wrote %s" % args[0])
	quit(0)
