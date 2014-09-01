##############################
#
# obj-Files
#
##############################

export WavefrontObjFile, 
    WavefrontObjFace, 
    readObjFile, 
    triangulate!, 
    computeNormals!, 
    compile, 
    compileMaterial

# type for obj faces
type WavefrontObjFace{T}
    ivertices::Vector{T}
    itexture_coords::Vector{T}
    inormals::Vector{T}

    material::String
    groups::Vector{String}
    smoothing_group::Int
end

# type for obj file data
type WavefrontObjFile{T,V}
    vertices::Vector{Vector3{T}}
    normals::Vector{Vector3{T}}
    tex_coords::Vector{Vector3{T}}
    
    faces::Vector{WavefrontObjFace{V}}

    groups::Dict{String, Array{Int}}
    smoothing_groups::Dict{Int, Array{Int}}

    mtllibs::Vector{String}
    materials::Dict{String, Array{Int}}
end 

function readObjFile(fn::String; vertextype=Float64, faceindextype=Int, triangulate::Bool=true, compute_normals::Bool=true)
    str = open(fn,"r")
    mesh = readObjFile(str, vertextype=vertextype, faceindextype=faceindextype, triangulate=triangulate, compute_normals=compute_normals)
    close(str)
    return mesh
end

# smoothing groups: "off" goes to smoothing group 0, so each face has a unique smoothing group
# faces with no material go to the empty material "", so each face has a unique material
function readObjFile{VT <: FloatingPoint, FT <: Integer}(io::IO; vertextype::Type{VT}=Float64, faceindextype::Type{FT}=Int, triangulate::Bool=true, compute_normals::Bool=true)
    readfloat(x::FloatingPoint) = convert(vertextype, x)
    readfloat(x::String)        = parsefloat(vertextype, x)
    readint(x::String)          = parseint(faceindextype, x)
    readint(x::Integer)         = convert(faceindextype, x)

    vs 	= Vector3{vertextype}[]
    nvs = Vector3{vertextype}[]
    uvs = Vector3{vertextype}[]
    fcs = WavefrontObjFace{faceindextype}[]

    groups                  = ["default" => Int[]]
    current_groups          = ["default"]
    smoothing_groups        = [0 => Int[]]
    current_smoothing_group = 0

    mtllibs = String[]
    materials = ["" => Int[]] # map material names to array with indieces of faces
    current_material = ""
    
    # face indices are allowed to be negative, these three methods handle that
    function vertexRef(s::String)
        i = int(s)
        if i < 0
            return readint(length(vs) + i +1)
        end
        return readint(i)
    end

    function normalRef(s::String)
        i = int(s)
        if i < 0
            return readint(length(nvs) + i +1)
        end
        return readint(i)
    end

    function textureRef(s::String)
        i = int(s)
        if i < 0
            return readint(length(uvs) + i +1)
        end
        return readint(i)
    end

    lineNumber = 1
    while !eof(io)

        # read a line, remove newline and leading/trailing whitespaces
        line = strip(chomp(readline(io)))
        
        @assert is_valid_ascii(line)

        if !beginswith(line, "#") && !isempty(line) && !iscntrl(line) #ignore comments
            line_parts = split(line)
            command    = line_parts[1]
            remainder  = length(line_parts) > 1 ? line[searchindex(line, line_parts[2]):end] : ""

            #vertex, 3 components only
            if command == "v" 
                push!(vs, Vector3{vertextype}(readfloat(line_parts[2]),
                                  readfloat(line_parts[3]),
                                  readfloat(line_parts[4])))         
            #texture coordinates, w is optional and defaults to 0
            elseif command == "vt" 
                if length(line_parts) == 4
                    push!(uvs, Vector3{vertextype}(readfloat(line_parts[2]),
                                    readfloat(line_parts[3]),
                                    readfloat(line_parts[4])))
                else
                    push!(uvs, Vector3{vertextype}(readfloat(line_parts[2]),
                                    readfloat(line_parts[3]),
                                    readfloat("0")))                    
                end
            #normals, 3 components
            elseif command == "vn" 
                push!(nvs, Vector3{vertextype}(readfloat(line_parts[2]),
                                  readfloat(line_parts[3]),
                                  readfloat(line_parts[4])))

            # faces: #/# or #/#/# or #//#. The first entrly determines the type for all following entries
            elseif command == "f" 
                @assert length(line_parts) >= 4
                face = WavefrontObjFace{faceindextype}([],[],[],"",[],0)

                # two slashes indicate #//#
                if (contains(line_parts[2], "//"))    
                    for i=2:length(line_parts)
                        v = split(line_parts[i], "//")
                        @assert length(v) == 2
                        push!(face.ivertices, vertexRef(v[1]))
                        push!(face.inormals, normalRef(v[2]))
                    end
                else
                    v = split(line_parts[2], "/")

                    if length(v) == 1
                        for i=2:length(line_parts)
                            push!(face.ivertices, vertexRef(line_parts[i]))
                        end
                    elseif length(v) == 2
                        for i=2:length(line_parts)
                            v = split(line_parts[i], "/")
                            @assert length(v) == 2
                            push!(face.ivertices, vertexRef(v[1]))
                            push!(face.itexture_coords, textureRef(v[2]))
                        end
                    elseif length(v) == 3
                        for i=2:length(line_parts)
                            v = split(line_parts[i], "/") 
                            @assert length(v) == 3
                            push!(face.ivertices, vertexRef(v[1]))
                            push!(face.itexture_coords, textureRef(v[2]))
                            push!(face.inormals, normalRef(v[3]))
                        end
                    else
                        println("WARNING: Illegal line while parsing wavefront .obj: '$line' (line $lineNumber)")
                        continue
                    end

                end
                
                # add face to groups, smoothing_group, material
                for group in current_groups
                    push!(groups[group], length(fcs)+1) 
                    push!(face.groups, group)
                end

                push!(materials[current_material], length(fcs)+1)
                face.material = current_material

                push!(smoothing_groups[current_smoothing_group], length(fcs)+1)
                face.smoothing_group = current_smoothing_group

                push!(fcs, face)

            # groups
            elseif command == "g"
                current_groups = String[]

                if length(line_parts) >= 2
                    for i=2:length(line_parts)
                        push!(current_groups, line_parts[i]) 
                        if !haskey(groups, line_parts[i])
                            groups[line_parts[i]] = Int[]
                        end
                    end
                else
                    current_groups = ["default"]
                end

            # set the smoothing group, 0 and off have the same meaning
            elseif command == "s" 
                if line_parts[2] == "off" 
                    current_smoothing_group = 0
                else
                    current_smoothing_group = int(line_parts[2])
                end

                if !haskey(smoothing_groups, current_smoothing_group)
                    smoothing_groups[current_smoothing_group] = Int[]
                end

            # material lib reference
            elseif command == "mtllib"
                for i=2:length(line_parts)
                    push!(mtllibs, line_parts[i])
                end

            # set a new material
            elseif command == "usemtl"
                current_material = line_parts[2]

                if !haskey(materials, current_material)
                    materials[current_material] = Int[]
                end

            # unknown line
            else 
                println("WARNING: Unknown line while parsing wavefront .obj: '$line' (line $lineNumber)")
            end
        end

        # read next line
        lineNumber += 1
    end

    # remove the "default" group, the 0 smoothing group and the empty material "" if they don't refer to any faces
    if isempty(groups["default"])
        delete!(groups, "default")
    end

    if isempty(smoothing_groups[0])
        delete!(smoothing_groups, 0)
    end

    if isempty(materials[""])
        delete!(materials, "")
    end

    # done reading the file, create the obj object!
    obj = WavefrontObjFile{vertextype,faceindextype}(vs, nvs, uvs, fcs, groups, smoothing_groups, mtllibs, materials)
    
    # triangulate and compute normals if wished
    if triangulate
    	triangulate!(obj)
    end

    if compute_normals
    	computeNormals!(obj)
    end

    return obj
end

# triangulate all polygons in an obj file
function triangulate!{vertextype,faceindextype}(obj::WavefrontObjFile{vertextype,faceindextype})
	i = 1
    while i <= length(obj.faces)
        face = obj.faces[i]

        if length(face.ivertices) > 3
        	# split a triangle
            triangle = WavefrontObjFace{faceindextype}(face.ivertices[1:3], [], [], face.material, copy(face.groups), copy(face.smoothing_group))
            splice!(face.ivertices, 2)

            if !isempty(face.itexture_coords)
                triangle.itexture_coords = face.itexture_coords[1:3]
                splice!(face.itexture_coords, 2)
            end
            if !isempty(face.inormals)
                triangle.inormals = face.inormals[1:3]
                splice!(face.inormals, 2)
            end

            # add new triangle to groups, smoothing_groups, material
            triangle_index = length(obj.faces)+1

           	for group in triangle.groups
                push!(obj.groups[group], triangle_index) 
            end

            push!(obj.materials[triangle.material], triangle_index)

            push!(obj.smoothing_groups[triangle.smoothing_group], triangle_index)

        	# done
            push!(obj.faces, triangle)
            continue
        end

        i += 1
    end
end

# does also work for polygons so no need to triangulate in advance
function computeNormals!{vertextype,faceindextype}(obj::WavefrontObjFile{vertextype,faceindextype}; override::Bool = false, smooth_normals::Bool = true)
	# override means: delete all normals prior to the computation
	if override
		obj.normals = []

		for face in obj.faces
			face.inormals = []
		end
	end

	# not smooth means an extra normal per face
	if !smooth_normals
        for face in obj.faces
        	if isempty(face.inormals)  
				e1 = obj.vertices[face.ivertices[2]] - obj.vertices[face.ivertices[1]]
            	e2 = obj.vertices[face.ivertices[3]] - obj.vertices[face.ivertices[2]]
            	n = unit(cross(e1,e2))

            	push!(obj.normals, n)

            	for ivertex in face.ivertices
            		push!(face.inormals, length(obj.normals))
            	end
        	end  
        end 

        return 
	end # not smooth

    # compute normals per smoothing group
    for sgroup in obj.smoothing_groups
        sgroup_ifaces = sgroup[2]

        # compute the normal for each face
        face_normals = (Int => Vector3{vertextype})[]

        for iface in sgroup_ifaces
            face = obj.faces[iface]
            e1 = obj.vertices[face.ivertices[2]] - obj.vertices[face.ivertices[1]]
            e2 = obj.vertices[face.ivertices[3]] - obj.vertices[face.ivertices[2]]
            n = unit(cross(e1,e2))

            face_normals[iface] = n
        end 

        # for each vertex, create an array of faces it belongs to
        vertex_faces = (Int => Array{Int})[]

        for iface in sgroup_ifaces
        	face = obj.faces[iface]

        	for ivertex in face.ivertices
        		if !haskey(vertex_faces, ivertex)
        			vertex_faces[ivertex] = Int[]
        		end

        		push!(vertex_faces[ivertex], iface)
        	end
        end 

        # we now know the indices of all vertices belonging to faces of the smoothing group
        sgroup_ivertices = collect(keys(vertex_faces))

        # for each vertex, compute the normal by taking the average value over all face normals
        vertex_normals = (Int => Vector3{vertextype})[]

        for ivertex in sgroup_ivertices
        	n = Vector3{vertextype}(0.0,0.0,0.0)

        	for iface in vertex_faces[ivertex]
        		n += face_normals[iface]
        	end

        	vertex_normals[ivertex] = unit(n)
       	end

        # for each face, set the vertex normals. Be sure to only add normals to the obj that we actually use,
        # i.e. where there's no normal present allready
        vertex_normal_index = (Int => Int)[]
        new_normals = Vector3{vertextype}[]

        for iface in sgroup_ifaces
        	face = obj.faces[iface]

        	if isempty(face.inormals)  
        		for ivertex in face.ivertices
        			# now add this normal to the obj because we use it!
	        		if !haskey(vertex_normal_index, ivertex)
	        			push!(new_normals, vertex_normals[ivertex])
	        			vertex_normal_index[ivertex] = length(new_normals)
	        		end

	        		push!(face.inormals, length(obj.normals) + vertex_normal_index[ivertex])      			
        		end
        	end
        end 

        # add used normals to the obj normals array
        obj.normals = [obj.normals, new_normals]
    end
end

function vertexIdTupel{T}(face::WavefrontObjFace{T}, i::Int)
    return (face.ivertices[i], isempty(face.inormals) ? -1 : face.inormals[i], isempty(face.itexture_coords) ? -1 : face.itexture_coords[i])
end

# this is the basic compilation function for faces
function compileVerticesNormalsTexCoords{vertextype,faceindextype}(obj::WavefrontObjFile{vertextype,faceindextype}, ifaces::Array{Int})
    vertices  = Vector3{vertextype}[]
    normals = Vector3{vertextype}[]
    tex_coords = Vector3{vertextype}[]

    mapping = ((Int,Int,Int) => Int)[]

    for iface in ifaces
        face = obj.faces[iface]

        for i = 1:length(face.ivertices)
            id_tupel = vertexIdTupel(face, i)

            if !haskey(mapping, id_tupel)
                push!(vertices, obj.vertices[face.ivertices[i]])
                push!(normals, isempty(face.inormals) ? Vector3{vertextype}(0.0,0.0,0.0) : obj.normals[face.inormals[i]])
                push!(tex_coords, isempty(face.itexture_coords) ? Vector3{vertextype}(0.0,0.0,0.0) : obj.tex_coords[face.itexture_coords[i]])

                mapping[id_tupel] = length(vertices)
            end
        end
    end

    return (vertices, normals, tex_coords, mapping)
end

# compile all faces belonging to a given material
function compileMaterial{vertextype,faceindextype}(obj::WavefrontObjFile{vertextype,faceindextype}, material::String)
    readint(x::Integer) = convert(faceindextype, x)

    (vs_compiled, nvs_compiled, uvs_compiled, mapping) = compileVerticesNormalsTexCoords(obj, obj.materials[material])

    fcs_compiled = Vector3{faceindextype}[]

    for face in obj.faces[obj.materials[material]]
        push!(fcs_compiled, Vector3{faceindextype}(readint(mapping[vertexIdTupel(face, 1)]-1),
                                                readint(mapping[vertexIdTupel(face, 2)]-1),
                                                readint(mapping[vertexIdTupel(face, 3)]-1) 
                ))
    end

    return (vs_compiled, nvs_compiled, uvs_compiled, fcs_compiled)
end

# compile all materials and return an id vector for them
function compile{vertextype,faceindextype}(obj::WavefrontObjFile{vertextype,faceindextype})
    readint(x::Integer) = convert(faceindextype, x)

    # compile materials separately and merge them
    vs_compiled     = Vector3{vertextype}[]
    nvs_compiled    = Vector3{vertextype}[]
    uvs_compiled    = Vector3{vertextype}[]
    material_id     = Uint8[]
    fcs_compiled    = Vector3{faceindextype}[]
    
    for (i, material) in enumerate( collect(keys(obj.materials)) )
        (m_vs_compiled, m_nvs_compiled, m_uvs_compiled, m_fcs_compiled) = compileMaterial(obj, material)

        m_material_id = zeros(Uint8, length(m_vs_compiled)) + i
        m_material_id  = Uint8[m_material_id[i] for i=1:length(m_material_id)]

        m_fcs_compiled = m_fcs_compiled + length(vs_compiled)
        m_fcs_compiled = Vector3{faceindextype}[m_fcs_compiled[i] for i=1:length(m_fcs_compiled)]

        vs_compiled     = [vs_compiled, m_vs_compiled]
        nvs_compiled    = [nvs_compiled, m_nvs_compiled]
        uvs_compiled    = [uvs_compiled, m_uvs_compiled]
        material_id     = [material_id, m_material_id]
        fcs_compiled    = [fcs_compiled, m_fcs_compiled]
    end

    return (vs_compiled, nvs_compiled, uvs_compiled, material_id, fcs_compiled)
end
