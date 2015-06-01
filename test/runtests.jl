using WavefrontObj, FileIO, MeshIO, GeometryTypes, GLVisualize, GLAbstraction
using Base.Test

obj  = read(file"cat.obj", GLNormalMesh)

function normals(verts, faces)
	normals_result = fill(Point3{Float32}(0), length(verts))
	for face in faces
		i1 = Int(face[1])
		i2 = Int(face[2])
		i3 = Int(face[3])

		v1 = verts[i1]
		v2 = verts[i2]
		v3 = verts[i3]
		a = v2 - v1
		b = v3 - v1
		n = cross(a,b)
		normals_result[i1] = n+normals_result[i1]
		normals_result[i2] = n+normals_result[i2]
		normals_result[i3] = n+normals_result[i3]
	end
	map(normalize, normals_result)
	convert(Normal3{Float32}, normals_result)
end
empty!(obj.attributes.normal)
append!(obj.attributes.normal, normals(obj.vertices, obj.faces))

obj.faces[:] = obj.faces - Uint32(1)
function funcy(x,y,z)
    Vec3(sin(x),cos(y),tan(z))
end
 
N = 15
directions  = Vec3[funcy(4x/N*3f0,4y/N,4z/N) for x=1:N,y=1:N, z=1:N]
robj 		= visualize(directions, primitive=obj)

push!(GLVisualize.ROOT_SCREEN.renderlist, robj)

renderloop()