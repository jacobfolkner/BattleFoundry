## A one-shot particle burst -- hit impacts, deaths, and ability casts all
## share this single component, differing only in color/amount/spread
## (see spawn()'s params). Purely cosmetic, matching this project's
## "primitive meshes/flat colors, no imported assets" convention (a tiny
## unshaded SphereMesh per particle, no texture). Self-frees once its own
## one-shot burst finishes (GPUParticles3D.finished only ever fires when
## one_shot is true).
class_name ImpactBurst
extends GPUParticles3D


static func spawn(parent: Node3D, position: Vector3, color: Color, amount: int = 10, spread_degrees: float = 45.0, initial_velocity: float = 3.0, lifetime: float = 0.35) -> void:
	var burst := ImpactBurst.new()
	parent.add_child(burst)
	burst.global_position = position
	burst.one_shot = true
	burst.amount = amount
	burst.lifetime = lifetime
	burst.explosiveness = 1.0
	burst.emitting = false # set true only after draw_pass_1/process_material are both assigned, below

	var particle_mesh := SphereMesh.new()
	particle_mesh.radius = 0.06
	particle_mesh.height = 0.12
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	particle_mesh.surface_set_material(0, material)
	burst.draw_pass_1 = particle_mesh

	var process_material := ParticleProcessMaterial.new()
	process_material.direction = Vector3(0, 1, 0)
	process_material.spread = spread_degrees
	process_material.initial_velocity_min = initial_velocity * 0.6
	process_material.initial_velocity_max = initial_velocity
	process_material.gravity = Vector3(0, -9.0, 0)
	process_material.scale_min = 0.5
	process_material.scale_max = 1.2
	burst.process_material = process_material

	burst.emitting = true
	burst.finished.connect(burst.queue_free)
