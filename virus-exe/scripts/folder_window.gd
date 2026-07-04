## 가짜 OS의 폴더 창. 스캔 상태에 따라 테두리 색으로 하이라이트된다.
extends Panel

enum Highlight { NONE, PREPARING, SCANNING, PASSED }

var title_text := ""

var _styles := {}


func _init(p_title: String, p_rect: Rect2) -> void:
	title_text = p_title
	position = p_rect.position
	size = p_rect.size


func _ready() -> void:
	_styles[Highlight.NONE] = _make_style(Color(0.55, 0.58, 0.62))
	_styles[Highlight.PREPARING] = _make_style(Color(0.95, 0.8, 0.2))
	_styles[Highlight.SCANNING] = _make_style(Color(0.9, 0.25, 0.25))
	_styles[Highlight.PASSED] = _make_style(Color(0.3, 0.8, 0.4))
	add_theme_stylebox_override("panel", _styles[Highlight.NONE])

	var bar := ColorRect.new()
	bar.color = Color(0.17, 0.32, 0.55)
	bar.position = Vector2(2.0, 2.0)
	bar.size = Vector2(size.x - 4.0, 26.0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)

	var title := Label.new()
	title.text = title_text
	title.position = Vector2(10.0, 4.0)
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)

	var close := Label.new()
	close.text = "X"
	close.position = Vector2(size.x - 24.0, 4.0)
	close.add_theme_font_size_override("font_size", 14)
	close.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.7))
	close.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(close)


func set_highlight(mode: int) -> void:
	add_theme_stylebox_override("panel", _styles[mode])


func _make_style(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.93, 0.94, 0.96)
	sb.set_border_width_all(3)
	sb.border_color = border
	sb.set_corner_radius_all(4)
	return sb
