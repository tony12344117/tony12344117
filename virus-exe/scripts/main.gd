## virus.exe — 게임 전체 컨트롤러.
## 가짜 바탕화면 UI를 코드로 전부 생성하고(아트 에셋 0개),
## 백신 상태 머신 / 드래그 은신 / 라운드 진행 / 연출을 묶는다.
##
## 로직 자동 테스트: godot --headless --path . -- --autotest
extends Control

const AntivirusScript := preload("res://scripts/antivirus.gd")
const FileIconScript := preload("res://scripts/file_icon.gd")
const FolderWindowScript := preload("res://scripts/folder_window.gd")

const SCREEN := Vector2(1280.0, 720.0)
const TASKBAR_H := 40.0
const LOC_TRASH := -1
const LOC_DESKTOP := 0
const LOCATION_NAMES := ["바탕화면", "내 문서", "다운로드", "사진"]
## 휴지통 은신 제한 시간 (초)
const TRASH_LIMIT := 4.0
## 큰 파일과 이 비율 이상 겹치면 "엄폐" 판정
const COVER_RATIO := 0.35

# 커스텀 스크립트 인스턴스들은 동적 디스패치를 위해 타입을 지정하지 않는다
# (Control/Node로 지정하면 커스텀 메서드 호출이 컴파일 에러가 된다)
var av
var windows := [null]
var big_icons := []
var player
var trash_icon

var player_location := LOC_DESKTOP
var trash_timer := 0.0
var game_started := false
var game_over := false
var elapsed := 0.0

# --- 통계 (라운드 클리어/게임오버 연출용) ---
var stat_close_calls_total := 0
var stat_close_round := 0
var stat_moves_round := 0
var stat_renames_round := 0

# --- UI 참조 ---
var desktop_frame: Panel
var desktop_styles := {}
var scan_line: ColorRect
var av_title: Label
var av_header: ColorRect
var av_status: Label
var av_target: Label
var av_progress: ProgressBar
var av_log: RichTextLabel
var round_label: Label
var clock_label: Label
var toast_label: Label
var toast_timer := 0.0
var trash_count_label: Label
var tutorial_layer: Control
var roundclear_layer: Control
var roundclear_title: Label
var roundclear_stats: Label
var roundclear_update: Label
var roundclear_timer := 0.0
var gameover_layer: Control
var gameover_stats: Label
var rename_layer: Control
var rename_edit: LineEdit
var shake_time := 0.0

# --- 스캔 중 서스펜스 추적 ---
## 이번 스캔 도중 한 순간이라도 "지금 걸리는 상태"였는가
var _player_was_in_danger := false
## 지금 이 순간 걸리는 상태인가 (플레이어 펄스 연출용)
var _player_in_danger := false
var _last_chance_shown := false
var _scan_area := Rect2()

## 한 번만 보여줄 튜토리얼 힌트 기록
var _hints_shown := {}

# --- 자동 테스트 상태 ---
var _autotest := false
var _t_detected := false
var _t_passed_desktop := false
var _t_fails := 0


func _ready() -> void:
	_build_background()
	_build_windows()
	_setup_antivirus()
	_build_trash()
	_build_icons()
	_build_scan_line()
	_build_av_window()
	_build_taskbar()
	_build_rename_dialog()
	_build_roundclear()
	_build_gameover()
	_build_tutorial()
	_build_toast()
	_refresh_player_visual()

	_autotest = "--autotest" in OS.get_cmdline_user_args()
	if _autotest:
		tutorial_layer.visible = false
		_run_autotest()
	else:
		# 게임은 튜토리얼의 [침투 시작] 버튼을 눌러야 시작된다
		tutorial_layer.visible = true


func _process(delta: float) -> void:
	if game_started and not game_over:
		elapsed += delta
		if player_location == LOC_TRASH:
			trash_timer -= delta
			trash_count_label.text = "%.1f" % maxf(trash_timer, 0.0)
			if trash_timer <= 0.0:
				_end_game("휴지통 비우기가 실행되어 함께 영구 삭제되었습니다.")
		_update_danger_pulse()
	if toast_timer > 0.0:
		toast_timer -= delta
		if toast_timer <= 0.0:
			toast_label.visible = false
	if roundclear_timer > 0.0:
		roundclear_timer -= delta
		if roundclear_timer <= 0.0:
			roundclear_layer.visible = false
	if shake_time > 0.0:
		shake_time -= delta
		position = Vector2(randf_range(-7.0, 7.0), randf_range(-5.0, 5.0))
		if shake_time <= 0.0:
			position = Vector2.ZERO
	if clock_label != null:
		clock_label.text = Time.get_time_string_from_system().substr(0, 5)


## 스캔이 내 위치를 훑는 동안, 걸릴 상태면 플레이어가 빨갛게 고동친다
func _update_danger_pulse() -> void:
	var pulsing: bool = _player_in_danger \
		and av.state == AntivirusScript.State.SCANNING \
		and av.current_location() == player_location
	if pulsing:
		var s := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.02)
		player.modulate = Color(1.0, 1.0 - 0.55 * s, 1.0 - 0.55 * s)
	elif player.modulate != Color.WHITE:
		player.modulate = Color.WHITE


# ---------------------------------------------------------------- UI 생성

func _build_background() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.42, 0.45)
	bg.size = SCREEN
	add_child(bg)

	desktop_styles[FolderWindowScript.Highlight.PREPARING] = _frame_style(Color(0.95, 0.8, 0.2))
	desktop_styles[FolderWindowScript.Highlight.SCANNING] = _frame_style(Color(0.9, 0.25, 0.25))
	desktop_styles[FolderWindowScript.Highlight.PASSED] = _frame_style(Color(0.3, 0.8, 0.4))
	desktop_frame = Panel.new()
	desktop_frame.size = SCREEN
	desktop_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desktop_frame.visible = false
	add_child(desktop_frame)


func _frame_style(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	sb.set_border_width_all(8)
	sb.border_color = border
	return sb


func _build_windows() -> void:
	var rects := [
		Rect2(430.0, 50.0, 360.0, 250.0),
		Rect2(830.0, 70.0, 380.0, 270.0),
		Rect2(480.0, 350.0, 330.0, 240.0),
	]
	for i in 3:
		var w: Panel = FolderWindowScript.new(LOCATION_NAMES[i + 1], rects[i])
		add_child(w)
		windows.append(w)


func _build_trash() -> void:
	trash_icon = _spawn_icon("휴지통", Vector2(1140.0, 540.0), {"trash": true, "draggable": false})
	trash_count_label = Label.new()
	trash_count_label.position = Vector2(1140.0, 505.0)
	trash_count_label.size = Vector2(100.0, 30.0)
	trash_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	trash_count_label.add_theme_font_size_override("font_size", 20)
	trash_count_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))
	trash_count_label.add_theme_color_override("font_outline_color", Color.BLACK)
	trash_count_label.add_theme_constant_override("outline_size", 6)
	trash_count_label.visible = false
	trash_count_label.z_index = 30
	add_child(trash_count_label)


func _build_icons() -> void:
	# 바탕화면 미끼들
	_spawn_icon("내 PC", Vector2(24.0, 30.0), {"draggable": false})
	_spawn_icon("보고서.hwp", Vector2(24.0, 150.0))
	_spawn_icon("가족사진.jpg", Vector2(24.0, 270.0))
	_spawn_icon("영화_4K.mp4", Vector2(340.0, 520.0), {"big": true})
	# 내 문서
	_spawn_icon("이력서.docx", Vector2(455.0, 95.0))
	_spawn_icon("메모.txt", Vector2(580.0, 95.0))
	# 다운로드
	_spawn_icon("백업.zip", Vector2(860.0, 115.0), {"big": true})
	_spawn_icon("설치파일.msi", Vector2(1030.0, 105.0))
	# 사진
	_spawn_icon("고양이.jpg", Vector2(505.0, 395.0))
	_spawn_icon("여행.png", Vector2(630.0, 395.0))
	# 플레이어
	player = _spawn_icon("virus.exe", Vector2(150.0, 40.0), {"player": true})
	player.dropped.connect(_on_player_dropped)
	player.drag_denied.connect(_on_player_drag_denied)
	player.rename_requested.connect(_on_player_rename_requested)


func _spawn_icon(icon_name: String, pos: Vector2, opts: Dictionary = {}):
	var icon = FileIconScript.new(icon_name, opts)
	icon.position = pos
	add_child(icon)
	if opts.get("big", false):
		big_icons.append(icon)
	if icon.draggable and not opts.get("player", false):
		icon.dropped.connect(_on_decoy_dropped)
	return icon


func _build_scan_line() -> void:
	scan_line = ColorRect.new()
	scan_line.color = Color(1.0, 0.3, 0.3, 0.3)
	scan_line.size = Vector2(SCREEN.x, 22.0)
	scan_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scan_line.z_index = 25
	scan_line.visible = false
	add_child(scan_line)


func _build_av_window() -> void:
	var panel := Panel.new()
	panel.position = Vector2(16.0, 424.0)
	panel.size = Vector2(300.0, 244.0)
	panel.z_index = 5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.18, 0.22)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.35, 0.55, 0.85)
	sb.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	av_header = ColorRect.new()
	av_header.color = Color(0.15, 0.35, 0.6)
	av_header.position = Vector2(2.0, 2.0)
	av_header.size = Vector2(296.0, 26.0)
	av_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(av_header)

	av_title = Label.new()
	av_title.text = "V-Guard 백신 4.0"
	av_title.position = Vector2(10.0, 4.0)
	av_title.add_theme_font_size_override("font_size", 14)
	av_title.add_theme_color_override("font_color", Color.WHITE)
	panel.add_child(av_title)

	av_status = Label.new()
	av_status.text = "시스템 검사 대기 중..."
	av_status.position = Vector2(12.0, 34.0)
	av_status.add_theme_font_size_override("font_size", 14)
	av_status.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	panel.add_child(av_status)

	av_target = Label.new()
	av_target.text = "다음 검사: -"
	av_target.position = Vector2(12.0, 56.0)
	av_target.add_theme_font_size_override("font_size", 13)
	av_target.add_theme_color_override("font_color", Color(1.0, 0.85, 0.6))
	panel.add_child(av_target)

	av_progress = ProgressBar.new()
	av_progress.position = Vector2(12.0, 80.0)
	av_progress.size = Vector2(276.0, 18.0)
	av_progress.min_value = 0.0
	av_progress.max_value = 100.0
	av_progress.value = 0.0
	panel.add_child(av_progress)

	av_log = RichTextLabel.new()
	av_log.bbcode_enabled = true
	av_log.scroll_following = true
	av_log.position = Vector2(12.0, 106.0)
	av_log.size = Vector2(276.0, 126.0)
	av_log.add_theme_font_size_override("normal_font_size", 12)
	panel.add_child(av_log)
	_log("[color=#9fb6d4]V-Guard 백신이 실행되었습니다.[/color]")


func _build_taskbar() -> void:
	var bar := Panel.new()
	bar.position = Vector2(0.0, SCREEN.y - TASKBAR_H)
	bar.size = Vector2(SCREEN.x, TASKBAR_H)
	bar.z_index = 5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.14, 0.18)
	bar.add_theme_stylebox_override("panel", sb)
	add_child(bar)

	var hb := HBoxContainer.new()
	hb.position = Vector2(8.0, 4.0)
	hb.size = Vector2(SCREEN.x - 16.0, TASKBAR_H - 8.0)
	hb.add_theme_constant_override("separation", 16)
	bar.add_child(hb)

	var start_btn := Button.new()
	start_btn.text = "시작"
	start_btn.custom_minimum_size = Vector2(80.0, 0.0)
	start_btn.pressed.connect(_on_start_button)
	hb.add_child(start_btn)

	round_label = Label.new()
	round_label.text = "라운드 1"
	round_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
	hb.add_child(round_label)

	var hint := Label.new()
	hint.text = "드래그: 이동 · 더블클릭: 이름 바꾸기 · 큰 파일 뒤: 은신 · 휴지통: 4초 대피"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.82))
	hb.add_child(hint)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)

	clock_label = Label.new()
	clock_label.text = "00:00"
	clock_label.add_theme_color_override("font_color", Color.WHITE)
	hb.add_child(clock_label)


func _build_rename_dialog() -> void:
	rename_layer = Control.new()
	rename_layer.size = SCREEN
	rename_layer.z_index = 80
	rename_layer.visible = false
	add_child(rename_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.45)
	dim.size = SCREEN
	rename_layer.add_child(dim)

	var panel := Panel.new()
	panel.position = Vector2((SCREEN.x - 440.0) * 0.5, 240.0)
	panel.size = Vector2(440.0, 200.0)
	rename_layer.add_child(panel)

	var title := Label.new()
	title.text = "파일 이름 바꾸기"
	title.position = Vector2(20.0, 12.0)
	title.add_theme_font_size_override("font_size", 18)
	panel.add_child(title)

	rename_edit = LineEdit.new()
	rename_edit.position = Vector2(20.0, 52.0)
	rename_edit.size = Vector2(400.0, 34.0)
	rename_edit.text_submitted.connect(_on_rename_submitted)
	panel.add_child(rename_edit)

	var hint := Label.new()
	hint.text = "팁: 흔한 문서나 사진처럼 보이는 이름이면 검사를 속일 수 있습니다.\n스캔 도중에도 바꿀 수 있습니다 — 마지막 1초의 역전!"
	hint.position = Vector2(20.0, 96.0)
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	panel.add_child(hint)

	var ok := Button.new()
	ok.text = "확인"
	ok.position = Vector2(250.0, 150.0)
	ok.size = Vector2(80.0, 34.0)
	ok.pressed.connect(_on_rename_confirm)
	panel.add_child(ok)

	var cancel := Button.new()
	cancel.text = "취소"
	cancel.position = Vector2(340.0, 150.0)
	cancel.size = Vector2(80.0, 34.0)
	cancel.pressed.connect(func() -> void: rename_layer.visible = false)
	panel.add_child(cancel)


func _build_roundclear() -> void:
	roundclear_layer = Control.new()
	roundclear_layer.size = SCREEN
	roundclear_layer.z_index = 40
	roundclear_layer.visible = false
	roundclear_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(roundclear_layer)

	var panel := Panel.new()
	panel.position = Vector2((SCREEN.x - 500.0) * 0.5, 120.0)
	panel.size = Vector2(500.0, 130.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.14, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = Color(1.0, 0.8, 0.3)
	sb.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	roundclear_layer.add_child(panel)

	roundclear_title = Label.new()
	roundclear_title.position = Vector2(0.0, 12.0)
	roundclear_title.size = Vector2(500.0, 30.0)
	roundclear_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	roundclear_title.add_theme_font_size_override("font_size", 22)
	roundclear_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	panel.add_child(roundclear_title)

	roundclear_stats = Label.new()
	roundclear_stats.position = Vector2(0.0, 48.0)
	roundclear_stats.size = Vector2(500.0, 24.0)
	roundclear_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	roundclear_stats.add_theme_font_size_override("font_size", 14)
	panel.add_child(roundclear_stats)

	roundclear_update = Label.new()
	roundclear_update.position = Vector2(0.0, 84.0)
	roundclear_update.size = Vector2(500.0, 36.0)
	roundclear_update.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	roundclear_update.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	roundclear_update.add_theme_font_size_override("font_size", 13)
	roundclear_update.add_theme_color_override("font_color", Color(1.0, 0.55, 0.4))
	panel.add_child(roundclear_update)


func _build_gameover() -> void:
	gameover_layer = Control.new()
	gameover_layer.size = SCREEN
	gameover_layer.z_index = 90
	gameover_layer.visible = false
	add_child(gameover_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.35, 0.0, 0.02, 0.75)
	dim.size = SCREEN
	gameover_layer.add_child(dim)

	var panel := Panel.new()
	panel.position = Vector2((SCREEN.x - 520.0) * 0.5, 200.0)
	panel.size = Vector2(520.0, 300.0)
	gameover_layer.add_child(panel)

	var title := Label.new()
	title.text = "바이러스가 격리되었습니다"
	title.position = Vector2(0.0, 24.0)
	title.size = Vector2(520.0, 40.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1.0, 0.4, 0.35))
	panel.add_child(title)

	gameover_stats = Label.new()
	gameover_stats.position = Vector2(30.0, 84.0)
	gameover_stats.size = Vector2(460.0, 110.0)
	gameover_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gameover_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(gameover_stats)

	var tip := Label.new()
	tip.text = "팁: 스캔 도중에도 이름 변경과 엄폐가 가능합니다. 마지막 1초를 노리세요!"
	tip.position = Vector2(0.0, 200.0)
	tip.size = Vector2(520.0, 24.0)
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 13)
	tip.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	panel.add_child(tip)

	var retry := Button.new()
	retry.text = "다시 침투하기"
	retry.position = Vector2((520.0 - 160.0) * 0.5, 240.0)
	retry.size = Vector2(160.0, 40.0)
	retry.pressed.connect(func() -> void: get_tree().reload_current_scene())
	panel.add_child(retry)


func _build_tutorial() -> void:
	tutorial_layer = Control.new()
	tutorial_layer.size = SCREEN
	tutorial_layer.z_index = 85
	tutorial_layer.visible = false
	add_child(tutorial_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.size = SCREEN
	tutorial_layer.add_child(dim)

	var panel := Panel.new()
	panel.position = Vector2((SCREEN.x - 560.0) * 0.5, 140.0)
	panel.size = Vector2(560.0, 400.0)
	tutorial_layer.add_child(panel)

	var title := Label.new()
	title.text = "virus.exe"
	title.position = Vector2(0.0, 24.0)
	title.size = Vector2(560.0, 40.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))
	panel.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "당신은 바이러스입니다. 백신에게 들키지 마세요."
	subtitle.position = Vector2(0.0, 68.0)
	subtitle.size = Vector2(560.0, 26.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 15)
	subtitle.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95))
	panel.add_child(subtitle)

	var body := Label.new()
	body.text = "1. 드래그 — 파일을 옮겨 검사를 피합니다.\n" \
		+ "2. 더블클릭 — 이름을 바꿔 평범한 파일로 위장합니다.\n" \
		+ "3. 큰 파일 뒤에 겹치거나, 휴지통(4초 한정)에 숨을 수 있습니다.\n\n" \
		+ "노란 테두리 = 다음 검사 위치. 미리 도망치세요.\n" \
		+ "빨간 테두리 = 검사 중. 파일이 잠기지만, 이름 변경과\n" \
		+ "엄폐는 스캔이 끝나기 전까지 가능합니다. 역전을 노리세요!\n\n" \
		+ "라운드를 버틸 때마다 백신이 업데이트되어 수법이 하나씩 막힙니다.\n" \
		+ "몇 라운드까지 살아남을 수 있습니까?"
	body.position = Vector2(48.0, 110.0)
	body.size = Vector2(470.0, 220.0)
	body.add_theme_font_size_override("font_size", 14)
	panel.add_child(body)

	var start := Button.new()
	start.text = "침투 시작"
	start.position = Vector2((560.0 - 180.0) * 0.5, 340.0)
	start.size = Vector2(180.0, 42.0)
	start.pressed.connect(_on_tutorial_start)
	panel.add_child(start)


func _build_toast() -> void:
	toast_label = Label.new()
	toast_label.position = Vector2(0.0, 620.0)
	toast_label.size = Vector2(SCREEN.x, 34.0)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.add_theme_font_size_override("font_size", 18)
	toast_label.add_theme_color_override("font_color", Color.WHITE)
	toast_label.add_theme_color_override("font_outline_color", Color.BLACK)
	toast_label.add_theme_constant_override("outline_size", 8)
	toast_label.visible = false
	toast_label.z_index = 100
	add_child(toast_label)


# ---------------------------------------------------------------- 백신 연결

func _setup_antivirus() -> void:
	av = AntivirusScript.new()
	av.location_count = LOCATION_NAMES.size()
	av.detection_check = _check_player_caught
	add_child(av)
	av.scan_preparing.connect(_on_scan_preparing)
	av.scan_started.connect(_on_scan_started)
	av.scan_progress.connect(_on_scan_progress)
	av.location_passed.connect(_on_location_passed)
	av.player_detected.connect(_on_player_detected)
	av.next_target.connect(_on_next_target)
	av.round_completed.connect(_on_round_completed)
	av.upgraded.connect(_on_upgraded)


## 스캔 종료 시점 발각 판정: 백신이 부르는 콜백
func _check_player_caught(loc: int) -> bool:
	if game_over:
		return false
	return _player_would_be_caught(loc)


## "지금 이 순간 loc에서 스캔이 끝나면 걸리는가" — 의심 연출에도 재사용
func _player_would_be_caught(loc: int) -> bool:
	if player_location != loc:
		return false
	if player.is_disguised() and not av.rename_patched:
		return false
	if _is_covered() and not av.cover_patched:
		return false
	return true


func _is_covered() -> bool:
	var pr: Rect2 = player.icon_rect_global()
	for big in big_icons:
		if not is_instance_valid(big):
			continue
		var inter: Rect2 = pr.intersection(big.icon_rect_global())
		if inter.get_area() >= pr.get_area() * COVER_RATIO:
			return true
	return false


func _area_rect(loc: int) -> Rect2:
	if loc == LOC_DESKTOP:
		return Rect2(0.0, 0.0, SCREEN.x, SCREEN.y - TASKBAR_H)
	return windows[loc].get_global_rect()


func _on_scan_preparing(i: int) -> void:
	_clear_highlights()
	_set_highlight(i, FolderWindowScript.Highlight.PREPARING)
	av_status.text = "검사 준비 중..."
	av_progress.value = 0.0
	if player_location == i:
		_toast("경고: %s 검사가 곧 시작됩니다!" % LOCATION_NAMES[i])
		if av.round_number == 1:
			_hint("move", "지금이에요! 드래그해서 다른 곳으로!", true)
	elif av.round_number == 1:
		_hint("prepare", "노란 테두리 = 다음 검사 위치입니다. 미리 피하세요.")


func _on_scan_started(i: int) -> void:
	_set_highlight(i, FolderWindowScript.Highlight.SCANNING)
	av_status.text = "검사 중: " + LOCATION_NAMES[i]
	_player_was_in_danger = false
	_player_in_danger = false
	_last_chance_shown = false
	_scan_area = _area_rect(i)
	scan_line.position = _scan_area.position
	scan_line.size = Vector2(_scan_area.size.x, 22.0)
	scan_line.visible = true
	if player_location == i:
		player.locked = true
		_toast("%s 검사 중 — 파일이 잠겼습니다! 위장하거나 숨으세요!" % LOCATION_NAMES[i])


func _on_scan_progress(i: int, ratio: float) -> void:
	av_progress.value = ratio * 100.0
	scan_line.position = Vector2(
		_scan_area.position.x,
		_scan_area.position.y + ratio * (_scan_area.size.y - 22.0)
	)
	if player_location != i:
		return
	# 의심 단계: 걸릴 상태면 백신이 "낌새를 챈" 것을 보여주고, 역전 기회를 준다
	_player_in_danger = _player_would_be_caught(i)
	if _player_in_danger:
		_player_was_in_danger = true
		av_status.text = "의심스러운 항목 정밀 분석 중..."
		if ratio >= 0.7 and not _last_chance_shown:
			_last_chance_shown = true
			_toast("마지막 기회! 이름을 바꾸거나 큰 파일 뒤로!")
	else:
		av_status.text = "검사 통과 중..."


func _on_location_passed(i: int) -> void:
	player.locked = false
	scan_line.visible = false
	_set_highlight(i, FolderWindowScript.Highlight.PASSED)
	_log("[color=#8fd694]%s: 위협 없음[/color]" % LOCATION_NAMES[i])
	av_status.text = "다음 위치로 이동 중..."
	if i == player_location:
		# 스캔 한복판에서 살아남았다 — 위기 탈출
		stat_close_round += 1
		stat_close_calls_total += 1
		if _player_was_in_danger:
			_float_text("구사일생!!", player.global_position + Vector2(20.0, -24.0), Color(1.0, 0.85, 0.3))
			_log("[color=#ffd479]정밀 분석 결과: 정상 파일 (오탐)[/color]")
		else:
			_float_text("휴우… 안 들켰다", player.global_position + Vector2(10.0, -24.0), Color(0.55, 0.95, 0.6))
	_player_in_danger = false
	_player_was_in_danger = false


func _on_player_detected(i: int) -> void:
	scan_line.visible = false
	_set_highlight(i, FolderWindowScript.Highlight.SCANNING)
	_log("[color=#ff7b7b]위협 탐지: '%s' → 격리 실행[/color]" % player.file_name)
	_float_text("발각!!", player.global_position + Vector2(24.0, -24.0), Color(1.0, 0.3, 0.3))
	shake_time = 0.35
	_end_game("백신이 '%s'에서 바이러스를 찾아냈습니다." % LOCATION_NAMES[i])


func _on_next_target(loc: int) -> void:
	av_target.text = "다음 검사: " + LOCATION_NAMES[loc]
	if loc == player_location:
		av_target.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))
		if game_started and not game_over:
			_toast("경고: 다음 목표는 지금 있는 곳입니다!")
	else:
		av_target.add_theme_color_override("font_color", Color(1.0, 0.85, 0.6))


func _on_round_completed(r: int) -> void:
	round_label.text = "라운드 %d" % (r + 1)
	_log("[color=#ffd479]== 라운드 %d 전체 검사 완료 ==[/color]" % r)
	if not _autotest:
		av.hold(2.6)
		roundclear_title.text = "라운드 %d 생존!" % r
		roundclear_stats.text = "이번 라운드 — 이동 %d회 · 위기 탈출 %d회 · 위장 %d회" \
			% [stat_moves_round, stat_close_round, stat_renames_round]
		roundclear_update.text = "백신 업데이트 수신 중..."
		roundclear_layer.visible = true
		roundclear_timer = 3.0
	stat_moves_round = 0
	stat_close_round = 0
	stat_renames_round = 0


func _on_upgraded(msg: String) -> void:
	_log("[color=#ff9d5c]업데이트 %s[/color]" % msg)
	roundclear_update.text = msg
	# 라운드가 오를수록 백신 창이 점점 붉어진다 — 적이 강해지는 게 보이도록
	av_title.text = "V-Guard 백신 %d.0" % (av.round_number + 3)
	av_header.color = Color(0.15, 0.35, 0.6).lerp(
		Color(0.62, 0.08, 0.1), clampf((av.round_number - 1) * 0.18, 0.0, 1.0)
	)
	_refresh_player_visual()


func _set_highlight(i: int, mode: int) -> void:
	if i == LOC_DESKTOP:
		if mode == FolderWindowScript.Highlight.NONE:
			desktop_frame.visible = false
		else:
			desktop_frame.visible = true
			desktop_frame.add_theme_stylebox_override("panel", desktop_styles[mode])
	else:
		windows[i].set_highlight(mode)


func _clear_highlights() -> void:
	desktop_frame.visible = false
	for i in range(1, windows.size()):
		windows[i].set_highlight(FolderWindowScript.Highlight.NONE)


# ---------------------------------------------------------------- 플레이어 조작

func _location_at(point: Vector2) -> int:
	if trash_icon.get_global_rect().grow(14.0).has_point(point):
		return LOC_TRASH
	for i in range(1, windows.size()):
		if windows[i].get_global_rect().has_point(point):
			return i
	return LOC_DESKTOP


func _on_player_dropped(icon) -> void:
	var center: Vector2 = icon.icon_rect_global().get_center()
	var new_loc := _location_at(center)
	var old_loc := player_location
	# 검사 중인 위치에서는 빠져나갈 수 없다 (파일 잠김)
	if av.state == AntivirusScript.State.SCANNING \
			and old_loc == av.current_location() \
			and new_loc != old_loc:
		icon.snap_back()
		_toast("검사 중인 위치에서 파일을 옮길 수 없습니다!")
		return
	var was_trash := old_loc == LOC_TRASH
	if new_loc == LOC_TRASH:
		icon.global_position = trash_icon.global_position + Vector2(0.0, -6.0)
		if not was_trash:
			trash_timer = TRASH_LIMIT
			trash_count_label.visible = true
			_toast("휴지통 은신 — %d초 안에 나가야 합니다!" % int(TRASH_LIMIT))
	elif was_trash:
		trash_count_label.visible = false
	player_location = new_loc
	icon.commit_position()
	if new_loc != old_loc:
		stat_moves_round += 1
	# 검사 준비(노란 테두리) 중에 그 위치에서 빠져나왔다면 — 아슬아슬한 탈출
	if av.state == AntivirusScript.State.PREPARING \
			and old_loc == av.current_location() and new_loc != old_loc:
		stat_close_round += 1
		stat_close_calls_total += 1
		_float_text("아슬아슬한 탈출!", player.global_position + Vector2(20.0, -24.0), Color(0.5, 0.9, 1.0))
	player.locked = av.state == AntivirusScript.State.SCANNING \
		and player_location == av.current_location()
	_refresh_player_visual()


func _on_player_drag_denied(_icon) -> void:
	_toast("파일이 검사 중이라 잠겨 있습니다!")


func _on_player_rename_requested(_icon) -> void:
	rename_layer.visible = true
	rename_edit.text = player.file_name
	rename_edit.grab_focus()
	rename_edit.select_all()


func _on_decoy_dropped(icon) -> void:
	var center: Vector2 = icon.icon_rect_global().get_center()
	if trash_icon.get_global_rect().grow(14.0).has_point(center):
		_toast("'%s' 파일이 삭제되었습니다." % icon.file_name)
		big_icons.erase(icon)
		icon.queue_free()
		return
	icon.commit_position()


func _on_rename_submitted(_text: String) -> void:
	_on_rename_confirm()


func _on_rename_confirm() -> void:
	var new_name := rename_edit.text.strip_edges()
	if new_name.is_empty():
		_toast("이름을 입력하세요.")
		return
	player.set_file_name(new_name)
	rename_layer.visible = false
	stat_renames_round += 1
	_refresh_player_visual()
	if player.is_disguised():
		if av.rename_patched:
			_toast("이름을 바꿨지만... 백신은 이미 속지 않습니다.")
		else:
			_toast("그럴듯한 이름이군요. 당분간은 통할지도?")
	else:
		_toast("여전히 수상해 보입니다...")


func _refresh_player_visual() -> void:
	if player == null:
		return
	# "현재 이름 상태로 정면 스캔을 맞으면 걸린다"는 경고 표시
	player.set_alert(not (player.is_disguised() and not av.rename_patched))


func _on_start_button() -> void:
	_toast("시작 메뉴는 아직 감염시키지 못했습니다.")


func _on_tutorial_start() -> void:
	tutorial_layer.visible = false
	game_started = true
	av.start()
	_toast("백신이 기동했습니다. 발각되지 마세요!")


# ---------------------------------------------------------------- 진행/종료

func _end_game(reason: String) -> void:
	if game_over:
		return
	game_over = true
	av.stop()
	player.locked = true
	scan_line.visible = false
	trash_count_label.visible = false
	roundclear_layer.visible = false
	gameover_stats.text = "%s\n\n생존 기록: 라운드 %d · %d초 · 위기 탈출 %d회" \
		% [reason, av.round_number, int(elapsed), stat_close_calls_total]
	gameover_layer.visible = true


func _toast(msg: String) -> void:
	toast_label.text = msg
	toast_label.visible = true
	toast_timer = 2.4


## 튜토리얼 힌트: key당 한 번만 표시
func _hint(key: String, msg: String, at_player := false) -> void:
	if _hints_shown.has(key):
		return
	_hints_shown[key] = true
	if at_player:
		_float_text(msg, player.global_position + Vector2(60.0, -16.0), Color(1.0, 0.95, 0.5))
	else:
		_toast(msg)


## 위로 떠오르며 사라지는 텍스트 (위기 탈출/발각 피드백)
func _float_text(text: String, pos: Vector2, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.z_index = 70
	label.add_theme_font_size_override("font_size", 21)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 8)
	add_child(label)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", pos.y - 48.0, 1.2)
	tween.tween_property(label, "modulate:a", 0.0, 0.7).set_delay(0.5)
	tween.chain().tween_callback(label.queue_free)


func _log(text: String) -> void:
	av_log.append_text(text + "\n")


# ---------------------------------------------------------------- 자동 테스트
# godot --headless --path . -- --autotest
# 렌더링 없이 발각/은신 로직과 라운드 업데이트 규칙을 검증한다.

func _run_autotest() -> void:
	print("[autotest] virus.exe 로직 검증 시작")
	av.player_detected.connect(func(_i: int) -> void: _t_detected = true)
	av.location_passed.connect(_on_test_location_passed)
	await get_tree().process_frame

	# T1: 위장 없는 플레이어는 바탕화면 스캔에서 발각된다
	_reset_for_test()
	av.start()
	var ok: bool = await _wait_until(func() -> bool: return _t_detected, 5.0)
	_check(ok, "T1: 위장 없는 플레이어는 스캔에서 발각된다")

	# T2: 파일명 위장은 스캔을 통과한다
	_reset_for_test()
	player.set_file_name("휴가사진.jpg")
	av.start()
	ok = await _wait_until(func() -> bool: return _t_passed_desktop, 5.0)
	_check(ok and not _t_detected, "T2: 파일명 위장은 스캔을 통과한다")

	# T3: 시그니처 업데이트 후에는 위장이 통하지 않는다
	_reset_for_test()
	av.rename_patched = true
	av.start()
	ok = await _wait_until(func() -> bool: return _t_detected, 5.0)
	_check(ok, "T3: 시그니처 업데이트 후에는 위장이 통하지 않는다")

	# T4: 큰 파일 뒤 은신은 통과한다 (위장이 막혀도)
	_reset_for_test()
	av.rename_patched = true
	player.global_position = big_icons[0].global_position
	_check(_is_covered(), "T4a: 큰 파일 겹침 판정이 성립한다")
	av.start()
	ok = await _wait_until(func() -> bool: return _t_passed_desktop, 5.0)
	_check(ok and not _t_detected, "T4b: 큰 파일 뒤 은신은 스캔을 통과한다")

	# T5: 휴리스틱 업데이트 후에는 겹침 은신도 발각된다
	_reset_for_test()
	av.rename_patched = true
	av.cover_patched = true
	av.start()
	ok = await _wait_until(func() -> bool: return _t_detected, 5.0)
	_check(ok, "T5: 휴리스틱 업데이트 후에는 겹침 은신도 발각된다")

	# T6: 라운드 업데이트 진행 순서
	_reset_for_test()
	av._complete_round()
	_check(av.rename_patched and not av.cover_patched, "T6a: 라운드 1 종료 -> 파일명 위장 무효화")
	var order_copy = av.scan_order.duplicate()
	order_copy.sort()
	_check(order_copy == range(av.location_count), "T6b: 라운드 2 검사 순서는 전체 위치의 순열이다")
	av._complete_round()
	_check(av.cover_patched and not av.rescan_enabled, "T6c: 라운드 2 종료 -> 겹침 은신 무효화")
	av._complete_round()
	_check(av.rescan_enabled, "T6d: 라운드 3 종료 -> 불시 재검사 활성화")

	print("[autotest] 완료 — 실패 %d건" % _t_fails)
	print("AUTOTEST %s" % ("PASS" if _t_fails == 0 else "FAIL"))
	get_tree().quit(0 if _t_fails == 0 else 1)


func _on_test_location_passed(i: int) -> void:
	if i == LOC_DESKTOP:
		_t_passed_desktop = true


func _reset_for_test() -> void:
	av.stop()
	game_over = false
	gameover_layer.visible = false
	_t_detected = false
	_t_passed_desktop = false
	av.reset()
	av.scan_duration = 0.12
	av.prepare_duration = 0.04
	av.between_duration = 0.04
	player.set_file_name("virus.exe")
	player.global_position = Vector2(150.0, 40.0)
	player_location = LOC_DESKTOP
	_player_in_danger = false
	_player_was_in_danger = false


func _wait_until(pred: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if pred.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return pred.call()


func _check(cond: bool, test_name: String) -> void:
	if cond:
		print("  [PASS] " + test_name)
	else:
		_t_fails += 1
		print("  [FAIL] " + test_name)
