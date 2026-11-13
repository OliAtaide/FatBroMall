shader_type spatial;
// Transparent dielectric glass with screen-space refraction, chromatic
// dispersion and an optional normal map. Approximates an offline path-traced
// glass material (e.g. FStorm) for real-time use in Godot 4.x.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// --- Scene buffer (the already-rendered frame behind this surface) ---
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

// --- Core glass look ---
uniform vec4  tint         : source_color        = vec4(1.0, 1.0, 1.0, 1.0); // transmitted color
uniform float roughness    : hint_range(0.0, 1.0) = 0.02;  // keep low for clear glass
uniform float specular_amt : hint_range(0.0, 1.0) = 0.5;
uniform float ior          : hint_range(1.0, 2.0) = 1.45;  // ~1.45-1.52 = glass
uniform float refraction   : hint_range(0.0, 1.0) = 0.06;  // screen-space bend strength
uniform float dispersion   : hint_range(0.0, 0.5) = 0.05;  // R/B split; 0 = off

// --- See-through ---
// The refracted sample (SCREEN_TEXTURE) only holds opaque objects, so other glass behind this
// surface, including a bottle's own far wall, only shows where these let it through.
// 1 = fully replaced by the refracted sample (the far glass is invisible).
uniform float opacity      : hint_range(0.0, 1.0) = 1.0;  // looking straight through
uniform float edge_opacity : hint_range(0.0, 1.0) = 1.0;  // at grazing angles, the silhouette
uniform float edge_falloff : hint_range(0.5, 8.0) = 3.0;  // higher = only the very edges
// Extra tint toward grazing angles, where light crosses more glass: draws the rims of every
// wall, which is what makes a far wall seen through a near one readable. White = off.
uniform vec4  edge_tint    : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// --- Normal-map variant (feed a tangent-space normal map) ---
uniform bool      use_normal_map     = false;
uniform sampler2D normal_map         : hint_normal;
uniform vec2      normal_scale       = vec2(1.0, 1.0);
uniform float     normal_strength    : hint_range(0.0, 2.0) = 1.0;

void fragment() {
	// 1) Optionally perturb the surface normal so both lighting AND the
	//    refraction offset react to the normal map (the "wavy glass" look).
	vec3 N = NORMAL; // NORMAL is in view space in the fragment shader
	if (use_normal_map) {
		// Normal maps imported as such keep only X and Y (blue reads 0, which would turn
		// the normal inside out), so Z is rebuilt from them
		vec2 nxy = (texture(normal_map, UV * normal_scale).xy * 2.0 - 1.0) * normal_strength;
		vec3 nm = vec3(nxy, sqrt(max(1.0 - dot(nxy, nxy), 0.0)));
		N = normalize(TANGENT * nm.x + BINORMAL * nm.y + NORMAL * nm.z);
		NORMAL = N; // let Godot's lighting/fresnel use the perturbed normal too
	}

	// 2) Screen-space refraction. Bend more for higher IOR. Using the view-space
	//    normal's XY as a screen offset is cheap and reads convincingly.
	float bend = refraction * (ior - 1.0);
	vec2 base_offset = -N.xy * bend;

	// 3) Chromatic dispersion: sample R/G/B with slightly different offsets so
	//    edges pick up the rainbow fringe. This is a fake of true spectral IOR.
	vec2 off_r = base_offset * (1.0 - dispersion);
	vec2 off_g = base_offset;
	vec2 off_b = base_offset * (1.0 + dispersion);

	vec3 transmitted;
	transmitted.r = texture(SCREEN_TEXTURE, SCREEN_UV + off_r).r;
	transmitted.g = texture(SCREEN_TEXTURE, SCREEN_UV + off_g).g;
	transmitted.b = texture(SCREEN_TEXTURE, SCREEN_UV + off_b).b;

	// 4) Fake absorption / colored glass by tinting the transmitted light, more so at the edges
	//    (where the view crosses more glass).
	float fresnel = pow(1.0 - clamp(dot(N, VIEW), 0.0, 1.0), edge_falloff);
	transmitted *= tint.rgb * mix(vec3(1.0), edge_tint.rgb, fresnel);

	// 5) Output. The transmitted image goes in EMISSION (unlit) so it isn't
	//    darkened by scene lighting. Godot's GGX specular + reflection probe /
	//    sky then adds the glossy highlights and Fresnel rim on top.
	EMISSION  = transmitted;
	ALBEDO    = vec3(0.0);
	METALLIC  = 0.0;
	ROUGHNESS = roughness;
	SPECULAR  = specular_amt;
	// 6) Cover what's already drawn behind (other glass) by the opacity, more at the edges
	//    like real glass; at 1 the refracted sample fully replaces it.
	ALPHA     = mix(opacity, edge_opacity, fresnel);
}
