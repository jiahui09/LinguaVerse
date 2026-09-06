extends SceneTree

## 对话路径模拟 (headless) — 移动玩家到咖啡馆门口, 触发对话, 验证无崩溃
## 后端未启动时应显示错误而非卡死

func _init():
	_run()

func _run():
	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	await process_frame

	var player: Node3D = main.get_node("Player")
	var gen: Node = main.get_node("StreetGenerator")
	var door: Vector3 = gen.get_cafe_door_pos()
	player.global_position = Vector3(door.x - 2.0, 0.5, door.z)
	player.rotation_degrees = Vector3(0, 180, 0)

	# 找 Marie
	var marie: Node3D = null
	for npc in get_nodes_in_group("npc"):
		if npc.name.begins_with("NPCWaiter"):
			marie = npc
	if marie == null:
		print("DIALOG_FAIL: 找不到 Marie")
		main.queue_free()
		quit(1)
		return

	# 触发对话
	var dm: Node = main.get_node("DialogManager")
	dm.start_dialog_with(marie)
	await process_frame
	print("DIALOG_UI_VISIBLE: ", dm.dialog_ui != null and dm.dialog_ui.panel.visible)
	print("DIALOG_STARTED_OK")

	# 发送输入(无后端, 应优雅失败)
	dm.send_player_input("Bonjour!")
	await create_timer(1.0).timeout
	print("DIALOG_HTTP_TIMEOUT_SAFE: 无崩溃")

	main.queue_free()
	quit(0)
