## 바탕화면 파일 아이콘.
## 플레이어(바이러스), 미끼 파일, 큰 파일(엄폐물), 휴지통을 모두 이 스크립트가 담당한다.
## 아트 에셋 없이 전부 _draw()로 그린다.
extends Control

signal drag_started(icon)
signal dropped(icon)
signal drag_denied(icon)
signal rename_requested(icon)

const SAFE_EXTENSIONS := [
	"txt", "jpg", "jpeg", "png", "gif", "mp3", "mp4", "docx", "pdf", "hwp", "xlsx", "zip",
]
const SUSPICIOUS_WORDS := ["virus", "바이러스", "malware", "trojan"]
const DRAG_Z := 50

var file_name := "file.txt"
var is_player := false
var is_big := false
var is_trash := false
var draggable := true
## true면 검사 중이라 드래그 불가 (파일 잠김)
var locked := false
## true면 "현재 상태로는 스캔에 걸린다"는 빨간 경고 테두리 표시
var alert := false
var icon_px := 64.0

var _label: Label
var _dragging := false
var _drag_offset := Vector2.ZERO
var _home_position := Vector2.ZERO
var _base_z := 1


func _init(p_name := "file.txt", opts: Dictionary = {}) -> void:
	file_name = p_name
	is_player = opts.get("player", false)
	is_big = opts.get("big", false)
	is_trash = opts.get("trash", false)
	draggable = opts.get("draggable", true)
	icon_px = 96.0 if is_big else 64.0


func _ready() -> void:
	size = Vector2(icon_px + 36.0, icon_px + 36.0)
	custom_minimum_size = size
	_base_z = 2 if is_big else 1
	z_index = _base_z
	mouse_filter = MOUSE_FILTER_STOP if draggable else MOUSE_FILTER_IGNORE
	if draggable:
		mouse_default_cursor_shape = CURSOR_POINTING_HAND
	_label = Label.new()
	_label.text = file_name
	_label.position = Vector2(0.0, icon_px + 6.0)
	_label.size = Vector2(size.x, 26.0)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_label)
	_home_position = global_position


func set_file_name(new_name: String) -> void:
	file_name = new_name
	if _label != null:
		_label.text = new_name
	queue_redraw()


func set_alert(value: bool) -> void:
	alert = value
	queue_redraw()


## 파일명이 "평범한 파일"처럼 보이는지 판정. 플레이어가 아니면 항상 true.
func is_disguised() -> bool:
	if not is_player:
		return true
	var lower := file_name.to_lower()
	for word in SUSPICIOUS_WORDS:
		if lower.find(word) != -1:
			return false
	return lower.get_extension() in SAFE_EXTENSIONS


## 그림(픽토그램) 영역의 전역 사각형. 겹침(엄폐) 판정에 사용.
func icon_rect_global() -> Rect2:
	var off := (size.x - icon_px) * 0.5
	return Rect2(global_position + Vector2(off, 0.0), Vector2(icon_px, icon_px))


func commit_position() -> void:
	_home_position = global_position


func snap_back() -> void:
	global_position = _home_position


func _gui_input(event: InputEvent) -> void:
	if not draggable:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.double_click and is_player:
				rename_requested.emit(self)
				return
			if locked:
				drag_denied.emit(self)
				return
			_dragging = true
			_drag_offset = get_global_mouse_position() - global_position
			z_index = DRAG_Z
			drag_started.emit(self)
		elif _dragging:
			_dragging = false
			z_index = _base_z
			dropped.emit(self)
	elif event is InputEventMouseMotion and _dragging:
		global_position = get_global_mouse_position() - _drag_offset


func _draw() -> void:
	var off := (size.x - icon_px) * 0.5
	var r := Rect2(Vector2(off, 0.0), Vector2(icon_px, icon_px))
	# 라벨 가독성용 반투명 배경
	draw_rect(Rect2(Vector2(0.0, icon_px + 4.0), Vector2(size.x, 24.0)), Color(0.0, 0.0, 0.0, 0.35))
	if is_trash:
		_draw_trash(r)
	elif is_player and not is_disguised():
		_draw_virus(r)
	else:
		_draw_file(r)
	if is_player:
		# 플레이어 식별 배지 (본인만 아는 표식이라는 설정)
		var badge := Vector2(r.position.x + 6.0, r.end.y - 6.0)
		draw_circle(badge, 6.0, Color(0.85, 0.1, 0.15))
		draw_circle(badge, 2.5, Color.WHITE)
		if alert:
			draw_rect(r.grow(3.0), Color(1.0, 0.2, 0.2, 0.9), false, 2.0)


func _draw_file(r: Rect2) -> void:
	var page := Rect2(
		r.position + Vector2(r.size.x * 0.16, r.size.y * 0.02),
		Vector2(r.size.x * 0.68, r.size.y * 0.94)
	)
	var fold := page.size.x * 0.32
	var x0 := page.position.x
	var y0 := page.position.y
	var x1 := page.end.x
	var y1 := page.end.y
	var body := PackedVector2Array([
		Vector2(x0, y0),
		Vector2(x1 - fold, y0),
		Vector2(x1, y0 + fold),
		Vector2(x1, y1),
		Vector2(x0, y1),
	])
	draw_colored_polygon(body, Color(0.96, 0.97, 0.99))
	draw_colored_polygon(PackedVector2Array([
		Vector2(x1 - fold, y0),
		Vector2(x1, y0 + fold),
		Vector2(x1 - fold, y0 + fold),
	]), Color(0.75, 0.78, 0.84))
	for i in 3:
		var line_y := y0 + page.size.y * (0.3 + 0.15 * i)
		draw_rect(
			Rect2(x0 + page.size.x * 0.15, line_y, page.size.x * 0.55, maxf(2.0, page.size.y * 0.05)),
			Color(0.62, 0.66, 0.72)
		)
	# 확장자에 따라 색이 달라지는 하단 띠
	var ext := file_name.get_extension().to_lower()
	var hue := fmod(absf(float(hash(ext))) * 0.000001, 1.0)
	draw_rect(
		Rect2(x0, y1 - page.size.y * 0.16, page.size.x, page.size.y * 0.16),
		Color.from_hsv(hue, 0.55, 0.75)
	)


func _draw_virus(r: Rect2) -> void:
	var c := r.get_center()
	var rad := r.size.x * 0.36
	for i in 8:
		var angle := TAU * i / 8.0
		draw_circle(c + Vector2.from_angle(angle) * rad, rad * 0.18, Color(0.45, 0.05, 0.08))
	draw_circle(c, rad, Color(0.62, 0.08, 0.1))
	draw_circle(c + Vector2(-rad * 0.35, -rad * 0.15), rad * 0.22, Color.WHITE)
	draw_circle(c + Vector2(rad * 0.35, -rad * 0.15), rad * 0.22, Color.WHITE)
	draw_circle(c + Vector2(-rad * 0.3, -rad * 0.12), rad * 0.1, Color.BLACK)
	draw_circle(c + Vector2(rad * 0.4, -rad * 0.12), rad * 0.1, Color.BLACK)


func _draw_trash(r: Rect2) -> void:
	var bx0 := r.position.x + r.size.x * 0.25
	var bx1 := r.end.x - r.size.x * 0.25
	var by0 := r.position.y + r.size.y * 0.3
	var by1 := r.end.y - r.size.y * 0.05
	draw_colored_polygon(PackedVector2Array([
		Vector2(bx0, by0),
		Vector2(bx1, by0),
		Vector2(bx1 - r.size.x * 0.06, by1),
		Vector2(bx0 + r.size.x * 0.06, by1),
	]), Color(0.72, 0.75, 0.8))
	var lid_w := (bx1 - bx0) + r.size.x * 0.12
	draw_rect(
		Rect2(bx0 - r.size.x * 0.06, by0 - r.size.y * 0.12, lid_w, r.size.y * 0.09),
		Color(0.6, 0.63, 0.68)
	)
	for i in 3:
		var slat_x := bx0 + r.size.x * 0.08 + i * r.size.x * 0.14
		draw_rect(Rect2(slat_x, by0 + r.size.y * 0.08, 3.0, (by1 - by0) * 0.7), Color(0.55, 0.58, 0.63))
