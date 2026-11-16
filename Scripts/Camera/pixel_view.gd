class_name PixelView
extends Node
## Renders the 3D world at low resolution and scales it up with crisp pixels.
## The HUD sits outside this, so the UI stays at full resolution.

## Extra low-res pixels on every side, so sliding by a sub-pixel never shows a gap.
const MARGIN: int = 1

@export var sub_viewport: SubViewport
@export var display: TextureRect

## Screen Pixels per world Pixel. 4 at 1080p gives a 480X270 world.
@export_range(1, 8) var pixel_scale: int = 4
## Draw the world at the window's full resolution instead (smooth, with FXAA),
## to compare the look with and without pixels. pixel_scale is ignored while this is on.
@export var native_resolution: bool = false

@export_group("Browser colour")
## The browser's renderer (Compatibility) lights the scene brighter and more saturated
## than desktop. These pull it back, in browser builds only (1 = unchanged).
## Darkens the mid-tones but keeps whites white (snow stays snow). 1 = unchanged,
## higher = darker.
@export_range(0.5, 2.0) var web_gamma: float = 1.25
@export_range(0.5, 1.5) var web_brightness: float = 1.0
@export_range(0.0, 1.5) var web_saturation: float = 0.8
@export_range(0.5, 1.5) var web_contrast: float = 1.0
## Use the browser colour on desktop too, to compare (editor testing).
@export var web_colour_always: bool = false
@export_group("")

const WEB_GRADE: String = """
shader_type canvas_item;
uniform float gamma = 1.0;
uniform float brightness = 1.0;
uniform float saturation = 1.0;
uniform float contrast = 1.0;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	vec3 graded = mix(vec3(luma), c.rgb, saturation);
	graded = (graded - 0.5) * contrast + 0.5;
	graded = pow(clamp(graded, 0.0, 1.0), vec3(gamma));
	COLOR = vec4(clamp(graded * brightness, 0.0, 1.0), c.a);
}
"""

var _base_position: Vector2 = Vector2.ZERO
var _zoom_scale: float = 1.0
## Screen units per world pixel: pixel_scale, or under 1 at native resolution (the
## window is usually bigger than the project's base size).
var _view_scale: float = 4.0

func _ready() -> void:
	display.texture = sub_viewport.get_texture()
	display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if native_resolution:
		display.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		# Not MSAA: it blends the buffer the outline pass reads its selection marks from.
		sub_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.stretch_mode = TextureRect.STRETCH_SCALE
	if web_colour_always or RenderingServer.get_current_rendering_method() == "gl_compatibility":
		_apply_web_grade()

	get_tree().root.size_changed.connect(_resize)
	_resize()
	ViewService.register(self)

## Tones the browser's brighter, more saturated picture down to match desktop.
func _apply_web_grade() -> void:
	var shader: Shader = Shader.new()
	shader.code = WEB_GRADE
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter(&"gamma", web_gamma)
	material.set_shader_parameter(&"brightness", web_brightness)
	material.set_shader_parameter(&"saturation", web_saturation)
	material.set_shader_parameter(&"contrast", web_contrast)
	display.material = material


func _exit_tree() -> void:
	ViewService.unregister(self)

func _unhandled_input(event: InputEvent) -> void:
	# Nodes inside a SubViewport only see input that's pushed to it (e.g. the
	# camera rig's zoom). Forward whatever the UI didn't use, scaled to low-res.
	var scale_down: Transform2D = Transform2D.IDENTITY.scaled(Vector2.ONE / _view_scale)
	sub_viewport.push_input(event.xformed_by(scale_down), true)

func screen_to_view(screen_position: Vector2) -> Vector2:
	# The display's transform includes its position, scale and pivot, so inverting it
	# maps any screen point back onto the low-res image, however it's slid or scaled.
	var on_display: Vector2 = display.get_global_transform().affine_inverse() * screen_position
	return on_display / _view_scale

func view_to_screen(view_position: Vector2) -> Vector2:
	return display.get_global_transform() * (view_position * _view_scale)

## Slide the image by a fraction of a low-res pixel (given in low-res pixels).
func apply_subpixel_offset(offset: Vector2) -> void:
	display.position = _base_position + offset * _view_scale * _zoom_scale

func apply_zoom_scale(zoom_scale: float) -> void:
	_zoom_scale = zoom_scale
	display.scale = Vector2(zoom_scale, zoom_scale)

## Change how chunky the world's pixels are (the camera does this at far zoom).
func set_pixel_scale(new_scale: int) -> void:
	if new_scale == pixel_scale or new_scale < 1 or native_resolution:
		return
	pixel_scale = new_scale
	_resize()


## Screen units per world pixel right now (pixel_scale, or a fraction at native resolution).
func get_view_scale() -> float:
	return _view_scale


func _resize() -> void:
	var screen: Vector2 = get_tree().root.get_visible_rect().size
	_view_scale = float(pixel_scale)
	if native_resolution:
		# One world pixel per real window pixel.
		_view_scale = screen.y / maxf(float(get_tree().root.size.y), 1.0)
	var low_res: Vector2i = Vector2i(ceili(screen.x / _view_scale), ceili(screen.y / _view_scale))
	low_res += Vector2i(MARGIN, MARGIN) * 2
	sub_viewport.size = low_res

	# Tuck the border just off-screen on every side.
	_base_position = -Vector2(MARGIN, MARGIN) * _view_scale
	display.position = _base_position
	display.size = Vector2(low_res) * _view_scale
	display.pivot_offset = display.size * 0.5
