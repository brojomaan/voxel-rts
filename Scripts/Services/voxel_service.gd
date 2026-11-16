extends Node
## Autoload as "VoxelService".
## Looks after the work voxel bodies share: loading each model once, and running their
## edits (hits, collapses) on background threads.
##
## An edit is a VoxelEditJob. It runs on the engine's worker threads; when it's done,
## this hands the result back to its body on the main thread. If a lot finish at once
## they're spread over a few frames (apply_budget_msec), so a barrage can't cause a
## hitch: craters just appear a frame or two late.

## Main-thread time per frame for applying finished edits. At least one is always
## applied, however long it takes.
var apply_budget_msec: float = 2.0

## Main-thread time spent applying edits in the last frame, in msec. For readouts.
var last_frame_msec: float = 0.0

## Loaded models: "path#index" -> VoxelModel.
var _models: Dictionary = {}
## Edits in flight: [task id, VoxelEditJob, VoxelBody].
var _running: Array[Array] = []


func _ready() -> void:
	VoxelMesher.warm_up()


func _exit_tree() -> void:
	# Let the workers finish before the game goes away under them.
	for entry: Array in _running:
		WorkerThreadPool.wait_for_task_completion(entry[0])
	_running.clear()


## The shared model for a .vox file (loaded and meshed the first time it's asked for).
## Returns null if the file can't be read.
func get_model(path: String, model_index: int = 0) -> VoxelModel:
	var key: String = "%s#%d" % [path, model_index]
	if _models.has(key):
		return _models[key]
	VoxelMesher.warm_up()
	var grid: VoxelGrid = VoxReader.load_grid(path, model_index)
	if grid == null:
		return null
	var model: VoxelModel = VoxelModel.new()
	model.build(grid)
	_models[key] = model
	return model


## Starts a job on a worker thread. body.apply_edit(job) is called on the main thread
## once it's finished (unless the body has gone by then).
func submit(job: VoxelEditJob, body: VoxelBody) -> void:
	var task: int = WorkerThreadPool.add_task(job.run, false, "Voxel edit")
	_running.append([task, job, body])


## Edits still being worked on (or waiting their turn to be applied).
func get_pending_count() -> int:
	return _running.size()


func _process(_delta: float) -> void:
	last_frame_msec = 0.0
	if _running.is_empty():
		return
	var t0: int = Time.get_ticks_usec()
	var i: int = 0
	while i < _running.size():
		var entry: Array = _running[i]
		if not WorkerThreadPool.is_task_completed(entry[0]):
			i += 1
			continue
		WorkerThreadPool.wait_for_task_completion(entry[0])
		_running.remove_at(i)
		if is_instance_valid(entry[2]):
			(entry[2] as VoxelBody).apply_edit(entry[1] as VoxelEditJob)
		if (Time.get_ticks_usec() - t0) / 1000.0 >= apply_budget_msec:
			break
	last_frame_msec = (Time.get_ticks_usec() - t0) / 1000.0
