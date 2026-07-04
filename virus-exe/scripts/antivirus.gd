## 백신 스캔 상태 머신.
## IDLE -> BETWEEN -> PREPARING -> SCANNING -> (통과: 다음 위치 / 발각: STOPPED)
## 한 라운드 = 모든 위치를 한 번씩 스캔. 라운드가 끝나면 "업데이트"로 위장 수법을 무효화한다.
extends Node

signal scan_preparing(location_index: int)
signal scan_started(location_index: int)
signal scan_progress(location_index: int, ratio: float)
signal location_passed(location_index: int)
signal player_detected(location_index: int)
signal round_completed(round_number: int)
signal upgraded(message: String)

enum State { IDLE, BETWEEN, PREPARING, SCANNING, STOPPED }

const BASE_SCAN_DURATION := 3.0
const BASE_PREPARE_DURATION := 1.5
const BASE_BETWEEN_DURATION := 1.2

## 스캔 대상 위치 수 (main이 설정)
var location_count := 4
## main이 넘겨주는 콜백: func(location_index: int) -> bool, true면 플레이어 발각
var detection_check := Callable()

var state: int = State.IDLE
var round_number := 1
var current_index := 0
var rename_patched := false
var cover_patched := false

var scan_duration := BASE_SCAN_DURATION
var prepare_duration := BASE_PREPARE_DURATION
var between_duration := BASE_BETWEEN_DURATION

var _timer := 0.0


func start() -> void:
	current_index = 0
	state = State.BETWEEN
	_timer = between_duration


func stop() -> void:
	state = State.STOPPED


func reset() -> void:
	state = State.IDLE
	round_number = 1
	current_index = 0
	rename_patched = false
	cover_patched = false
	scan_duration = BASE_SCAN_DURATION
	prepare_duration = BASE_PREPARE_DURATION
	between_duration = BASE_BETWEEN_DURATION
	_timer = 0.0


func _process(delta: float) -> void:
	match state:
		State.BETWEEN:
			_timer -= delta
			if _timer <= 0.0:
				state = State.PREPARING
				_timer = prepare_duration
				scan_preparing.emit(current_index)
		State.PREPARING:
			_timer -= delta
			if _timer <= 0.0:
				state = State.SCANNING
				_timer = scan_duration
				scan_started.emit(current_index)
		State.SCANNING:
			_timer -= delta
			var ratio := clampf(1.0 - _timer / scan_duration, 0.0, 1.0)
			scan_progress.emit(current_index, ratio)
			if _timer <= 0.0:
				_finish_location()


func _finish_location() -> void:
	var caught := false
	if detection_check.is_valid():
		caught = detection_check.call(current_index)
	if caught:
		state = State.STOPPED
		player_detected.emit(current_index)
		return
	location_passed.emit(current_index)
	current_index += 1
	if current_index >= location_count:
		_complete_round()
	state = State.BETWEEN
	_timer = between_duration


func _complete_round() -> void:
	round_completed.emit(round_number)
	round_number += 1
	current_index = 0
	scan_duration = maxf(1.0, scan_duration * 0.85)
	prepare_duration = maxf(0.5, prepare_duration * 0.9)
	between_duration = maxf(0.4, between_duration * 0.9)
	if round_number == 2:
		rename_patched = true
		upgraded.emit("v2.0 시그니처 DB 갱신 — 파일명 위장이 더 이상 통하지 않습니다!")
	elif round_number == 3:
		cover_patched = true
		upgraded.emit("v3.0 휴리스틱 스캔 — 다른 파일 뒤에 숨어도 탐지됩니다!")
	else:
		upgraded.emit("v%d.0 스캔 엔진 최적화 — 검사가 더 빨라집니다!" % round_number)
