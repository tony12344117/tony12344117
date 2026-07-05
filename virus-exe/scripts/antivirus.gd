## 백신 스캔 상태 머신.
## IDLE -> BETWEEN -> PREPARING -> SCANNING -> (통과: 다음 위치 / 발각: STOPPED)
## 한 라운드 = scan_order의 모든 위치를 한 번씩 스캔.
##
## 라운드 진행에 따른 난이도 상승:
##   라운드 1  : 튜토리얼 페이스 (느림), 순서 고정
##   라운드 2  : 파일명 위장 무효화 + 스캔 순서 무작위화 + 정상 속도
##   라운드 3  : 엄폐(겹침) 은신 무효화
##   라운드 4  : 불시 재검사 (이미 검사한 위치도 확률적으로 다시 스캔)
##   라운드 5+ : 스캔 속도 계속 증가
extends Node

signal scan_preparing(location_index: int)
signal scan_started(location_index: int)
signal scan_progress(location_index: int, ratio: float)
signal location_passed(location_index: int)
signal player_detected(location_index: int)
signal next_target(location_index: int)
signal round_completed(round_number: int)
signal upgraded(message: String)

enum State { IDLE, BETWEEN, PREPARING, SCANNING, HOLD, STOPPED }

const BASE_SCAN_DURATION := 3.0
const BASE_PREPARE_DURATION := 1.5
const BASE_BETWEEN_DURATION := 0.9
## 라운드 1은 튜토리얼 페이스로 느리게
const TUTORIAL_SCAN_DURATION := 3.5
const TUTORIAL_PREPARE_DURATION := 2.5
const TUTORIAL_BETWEEN_DURATION := 1.5
## 라운드 4+: 스캔 하나가 끝날 때마다 이 확률로 이미 검사한 곳을 재검사
const RESCAN_CHANCE := 0.2

## 스캔 대상 위치 수 (main이 설정)
var location_count := 4
## main이 넘겨주는 콜백: func(location_index: int) -> bool, true면 플레이어 발각
var detection_check := Callable()

var state: int = State.IDLE
var round_number := 1
## 이번 라운드의 스캔 순서 (위치 인덱스 배열). 재검사 삽입으로 길어질 수 있다.
var scan_order := [0, 1, 2, 3]
## scan_order 상의 현재 위치
var current_index := 0
var rename_patched := false
var cover_patched := false
var rescan_enabled := false

var scan_duration := TUTORIAL_SCAN_DURATION
var prepare_duration := TUTORIAL_PREPARE_DURATION
var between_duration := TUTORIAL_BETWEEN_DURATION

var _timer := 0.0


## 지금 스캔 중(또는 스캔 예정)인 실제 위치 인덱스
func current_location() -> int:
	return scan_order[current_index]


func start() -> void:
	_new_round_order()
	current_index = 0
	state = State.BETWEEN
	_timer = between_duration
	next_target.emit(current_location())


func stop() -> void:
	state = State.STOPPED


## 라운드 클리어 연출 등을 위해 잠시 진행을 멈춘다 (BETWEEN 상태에서만)
func hold(seconds: float) -> void:
	if state == State.BETWEEN:
		state = State.HOLD
		_timer = seconds


func reset() -> void:
	state = State.IDLE
	round_number = 1
	current_index = 0
	rename_patched = false
	cover_patched = false
	rescan_enabled = false
	scan_duration = TUTORIAL_SCAN_DURATION
	prepare_duration = TUTORIAL_PREPARE_DURATION
	between_duration = TUTORIAL_BETWEEN_DURATION
	_new_round_order()
	_timer = 0.0


func _process(delta: float) -> void:
	match state:
		State.HOLD:
			_timer -= delta
			if _timer <= 0.0:
				state = State.BETWEEN
				_timer = between_duration
		State.BETWEEN:
			_timer -= delta
			if _timer <= 0.0:
				state = State.PREPARING
				_timer = prepare_duration
				scan_preparing.emit(current_location())
		State.PREPARING:
			_timer -= delta
			if _timer <= 0.0:
				state = State.SCANNING
				_timer = scan_duration
				scan_started.emit(current_location())
		State.SCANNING:
			_timer -= delta
			var ratio := clampf(1.0 - _timer / scan_duration, 0.0, 1.0)
			scan_progress.emit(current_location(), ratio)
			if _timer <= 0.0:
				_finish_location()


func _finish_location() -> void:
	var loc := current_location() as int
	var caught = false
	if detection_check.is_valid():
		caught = detection_check.call(loc)
	if caught:
		state = State.STOPPED
		player_detected.emit(loc)
		return
	location_passed.emit(loc)
	# 라운드 4+: 이미 검사한 위치를 불시에 다시 검사 (안전지대 제거)
	if rescan_enabled and randf() < RESCAN_CHANCE:
		var revisit = scan_order[randi() % (current_index + 1)]
		scan_order.insert(current_index + 1, revisit)
	current_index += 1
	state = State.BETWEEN
	_timer = between_duration
	if current_index >= scan_order.size():
		_complete_round()
	next_target.emit(current_location())


func _new_round_order() -> void:
	scan_order = range(location_count)
	if round_number >= 2:
		scan_order.shuffle()


func _complete_round() -> void:
	round_completed.emit(round_number)
	round_number += 1
	current_index = 0
	_new_round_order()
	if round_number == 2:
		# 튜토리얼 페이스 종료 + 위장 무효화 + 순서 무작위화
		scan_duration = BASE_SCAN_DURATION
		prepare_duration = BASE_PREPARE_DURATION
		between_duration = BASE_BETWEEN_DURATION
		rename_patched = true
		upgraded.emit("v2.0 시그니처 DB 갱신 — 파일명 위장 무효화. 검사 순서도 뒤섞입니다!")
	elif round_number == 3:
		cover_patched = true
		_speed_up()
		upgraded.emit("v3.0 휴리스틱 스캔 — 다른 파일 뒤에 숨어도 탐지됩니다!")
	elif round_number == 4:
		rescan_enabled = true
		_speed_up()
		upgraded.emit("v4.0 실시간 감시 — 이미 검사한 곳도 불시에 재검사합니다!")
	else:
		_speed_up()
		upgraded.emit("v%d.0 스캔 엔진 최적화 — 검사가 더 빨라집니다!" % round_number)


func _speed_up() -> void:
	scan_duration = maxf(1.0, scan_duration * 0.85)
	prepare_duration = maxf(0.5, prepare_duration * 0.9)
	between_duration = maxf(0.35, between_duration * 0.9)
