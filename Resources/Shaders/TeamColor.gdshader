// Team-color infrastructure -- first real shader in this project (every
// other material is a plain StandardMaterial3D). Behaves identically to
// the flat albedo_color material it replaces as long as albedo_texture/
// team_mask stay at their default white -- team_color alone drives the
// surface color, same as before, and unit.gd sets it through exactly the
// same hit-flash/decay lerp logic it always did (see Unit._body_material).
//
// The point is the two texture uniforms: a future imported model can plug
// in albedo_texture (its real diffuse map) and team_mask (a mask painted
// into an unused channel marking which pixels are "team color," the same
// technique WC3 itself used) without any further Unit.gd changes -- only
// team_mask's white pixels blend toward team_color, everything else keeps
// the base texture untouched.
shader_type spatial;
render_mode blend_mix, depth_draw_always;

uniform vec4 team_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform sampler2D team_mask : hint_default_white;

void fragment() {
	vec3 base = texture(albedo_texture, UV).rgb;
	float mask = texture(team_mask, UV).r;
	ALBEDO = mix(base, team_color.rgb, mask);
	ALPHA = team_color.a;
}
