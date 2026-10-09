shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;

// Haussmann 建筑立面程序化窗户 Shader
// 应用于临街薄盒(0.12 厚 BoxMesh), 大面法线 ±X(朝向街道)
// UV.x 沿街宽方向, UV.y 沿高度方向(底面为 0)
// uniform 由 street_generator.gd 按每栋实际尺寸设置
// 注意: Godot4 fragment() 内禁止 return, 全部用嵌套 if + 变量赋值

uniform vec3 wall_col : source_color = vec3(0.96, 0.93, 0.88);   // 奶白石灰岩
uniform vec3 trim_col : source_color = vec3(0.78, 0.76, 0.72);   // 线脚
uniform vec3 window_col : source_color = vec3(0.16, 0.22, 0.32); // 窗玻璃(深蓝)
uniform vec3 frame_col : source_color = vec3(0.30, 0.28, 0.26);  // 窗框(铁灰)
uniform vec3 shop_col : source_color = vec3(0.15, 0.28, 0.17);   // 底层商铺门面
uniform vec3 shop_glass : source_color = vec3(0.35, 0.55, 0.62); // 橱窗玻璃

uniform float wall_width_m : hint_range(1.0, 60.0) = 10.0;   // 立面实际宽(米)
uniform float wall_height_m : hint_range(2.0, 60.0) = 18.0;  // 立面实际高(米)
// hint_range 运行时也 clamp 参数: 原上限 12/6 会把宽街墙的层数/跨数夹满
// (旧默认 10×18 恒在范围内, 批次6 传实际尺寸才暴露 → 巨窗失真)
uniform int levels : hint_range(1, 24) = 6;                  // 层数
uniform int windows_per_floor : hint_range(1, 32) = 2;       // 每层窗洞数
uniform bool ground_shop = false;                            // 底层是否商铺
uniform float night_glow : hint_range(0.0, 1.0) = 0.0;       // 夜间窗内暖光

// P3 批次6: 墙身石灰拉毛贴图 (make_textures facade 族, 环面可平铺)
// wall_tex_on=false 时保持原纯色行为 (贴图缺失诚实降级, street_check 会报红)
uniform sampler2D wall_tex : source_color, filter_linear_mipmap;
// 法线数据纹理不给 type hint: source_color/hint_default_normal 在 4.7 下
// 组合或命名会被拒 ("Expected valid type hint after ':'" → 编译失败 →
// llvmpipe 真渲染整面 fallback, headless 门禁不编译 shader 抓不到); 我们总是传真实纹理
uniform sampler2D wall_nrm : filter_linear_mipmap;
uniform float wall_tile_m : hint_range(0.5, 8.0) = 1.6;
uniform bool wall_tex_on = false;

varying vec3 v_normal_local;

void vertex() {
	// 模型空间法线(BoxMesh 各面法线为 ±轴单位向量)
	v_normal_local = NORMAL;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	// 世界尺寸坐标(米)
	float px = UV.x * wall_width_m;
	float py = UV.y * wall_height_m;
	float h_from_ground = py;

	vec3 n = normalize(v_normal_local);
	bool is_facade = abs(n.x) > 0.5;

	// 输出初值: 非立面(顶/侧/底) = 纯墙色
	vec3 albedo = wall_col;
	float rough = 0.9;
	float metal = 0.0;
	bool use_wall_tex = true;   // 墙区才叠拉毛贴图 (窗/门面/线脚/雨棚带不叠)

	if (is_facade) {
		// ===== 底层商铺(地面向上 ~4.2m) =====
		float shop_h = 4.2;
		if (h_from_ground < shop_h) {
			if (ground_shop) {
				float shop_glass_bottom = 1.6;
				float shop_glass_top = 3.4;
				float bay = 2.8;
				float bx = fract(px / bay);
				bool glass = h_from_ground > shop_glass_bottom && h_from_ground < shop_glass_top;
				bool in_glass_span = bx > 0.10 && bx < 0.90;
				albedo = shop_col;
				rough = 0.7;
				use_wall_tex = false;
				if (glass && in_glass_span) {
					float seed = hash12(vec2(floor(px / bay), 0.0));
					albedo = shop_glass * (0.85 + 0.15 * seed);
					rough = 0.1;
					metal = 0.2;
				} else if (h_from_ground > 3.4 && h_from_ground < 3.8) {
					// 雨棚阴影带
					albedo = trim_col * 0.7;
					rough = 0.9;
				}
			} else {
				albedo = wall_col;
				rough = 0.85;
			}
		} else {
			// ===== 标准层窗户 =====
			float usable_h = wall_height_m - shop_h;
			float floor_h = usable_h / float(max(1, levels));
			float py_above = py - shop_h;
			float fy = fract(py_above / floor_h);   // 层内 0..1 (下→上)
			float bay_w = wall_width_m / float(max(1, windows_per_floor));
			float bx = fract(px / bay_w);

			bool win_v = fy > 0.22 && fy < 0.88;
			// 窗宽收窄至跨 48% (原 72% → 窗间墙仅 0.7m, 中远看像整条玻璃带;
			// 巴黎奥斯曼立面窗宽 ~1.2-1.4m、窗间墙 ~1.4m 的比例)
			bool win_h = bx > 0.26 && bx < 0.74;
			bool sill = fy > 0.88 && fy < 0.94;      // 窗台
			bool floor_band = fy >= 0.94;            // 楼板带
			bool balcony = fy < 0.06;                // 阳台铁艺

			albedo = wall_col;
			rough = 0.9;
			if (win_v && win_h) {
				float split = 0.5;
				bool upper = fy > 0.22 + split * (0.88 - 0.22);
				float glow = night_glow * (0.55 + 0.45 * hash12(vec2(px * 3.7, py * 2.3)));
				vec3 glass = mix(window_col, vec3(1.0, 0.82, 0.5), glow);
				if (upper && hash12(vec2(px, py)) > 0.93) {
					glass = vec3(0.1, 0.1, 0.12) * 0.3;
				}
				albedo = glass;
				rough = 0.25;
				metal = 0.1;
				use_wall_tex = false;
			} else if (sill) {
				albedo = trim_col * 0.9;
				rough = 0.85;
				use_wall_tex = false;
			} else if (floor_band) {
				albedo = trim_col;
				rough = 0.75;
				use_wall_tex = false;
			} else if (balcony) {
				albedo = frame_col;
				rough = 0.6;
				use_wall_tex = false;
			}
		}
	}

	// 墙区叠石灰拉毛贴图: 乘算保持统一色调 (贴图均值 ≈0.93 → 除回补偿)
	if (wall_tex_on && use_wall_tex) {
		vec2 tuv = vec2(px, py) / wall_tile_m;
		albedo *= texture(wall_tex, tuv).rgb / 0.93;
		NORMAL_MAP = texture(wall_nrm, tuv).rgb;
		NORMAL_MAP_DEPTH = 0.5;
	}

	ALBEDO = albedo;
	ROUGHNESS = rough;
	METALLIC = metal;
}
