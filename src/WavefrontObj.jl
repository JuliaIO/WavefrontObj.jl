module WavefrontObj

using ImmutableArrays

export WavefrontObjFile, WavefrontObjFace, readObjFile, computeNormals!, compile
export WavefrontMtlMaterial, readMtlFile

##############################
#
# Obj-Files
#
##############################

# f 
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

function readObjFile(fn::String; vertextype=Float64, faceindextype=Int)
    str = open(fn,"r")
    mesh = readObjFile(str, vertextype=vertextype, faceindextype=faceindextype)
    close(str)
    return mesh
end

# smoothing groups: "off" goes to smoothing group 0, so each face has a unique smoothing group
function readObjFile{VT <: FloatingPoint, FT <: Integer}(io::IO; vertextype::Type{VT}=Float64, faceindextype::Type{FT}=Int)
    readfloat(x::FloatingPoint) = convert(vertextype, x)
    readfloat(x::String)        = parsefloat(vertextype, x)
    readint(x::String)          = parseint(faceindextype, x)
    readint(x::Integer)         = convert(faceindextype, x)

    vs 	= Vector3{vertextype}[]
    nvs = Vector3{vertextype}[]
    uvs = Vector3{vertextype}[]
    fcs = WavefrontObjFace{faceindextype}[]

    groups                  = (String => Array{Int})[]
    current_groups          = String[]
    smoothing_groups        = [0 => Int[]]
    current_smoothing_group = 0

    mtllibs = String[]
    materials = (String => Array{Int})[] # map material names to array with indieces of faces
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
                
                # add face to groups, smoothing_groups, material
                for group in current_groups
                    push!(groups[group], length(fcs)+1) 
                    push!(face.groups, group)
                end

                if current_material != ""
                    push!(materials[current_material], length(fcs)+1)
                    face.material = current_material
                end

                push!(smoothing_groups[current_smoothing_group], length(fcs)+1)
                face.smoothing_group = current_smoothing_group

                push!(fcs, face)

            # groups
            elseif command == "g"
                current_groups = String[];

                if length(line_parts) >= 2
                    for i=2:length(line_parts)
                        push!(current_groups, line_parts[i]) 
                        if !haskey(groups, line_parts[i])
                            groups[line_parts[i]] = Int[]
                        end
                    end
                else
                    current_groups = ["default"];
                    if !haskey(groups, "default")
                        groups["default"] = Int[]
                    end
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
                current_material = line_parts[2];

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

    # triangulate polygons
    i = 1
    while i <= length(fcs)
        face = fcs[i]

        if length(face.ivertices) > 3
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

            # add face to groups, smoothing_groups, material


            #for group in triangle.groups
            #    push!(groups[group], length(fcs)+1) 
            #end
#TODO material
          #  if current_material != ""
         #      push!(materials[current_material], length(fcs)+1)
           # end

            push!(smoothing_groups[triangle.smoothing_group], length(fcs)+1)

            push!(fcs, triangle)
            continue
        end

        i += 1
    end

    return WavefrontObjFile{vertextype,faceindextype}(vs, nvs, uvs, fcs, groups, smoothing_groups, mtllibs, materials)
end

function computeNormals!{vertextype,faceindextype}(obj::WavefrontObjFile{vertextype,faceindextype}, override::Bool = false)
    #= in the first step, duplicate vertices that belong to more than one smoothing group
    vertex_smoothing_groups = zeros[Int, length(obj.vertices)]

    for face in obj.faces # for each face
        for i=1:3 # for each vertex that belongs to the face
            ivertex = face.vertices[i]

            if vertex_smoothing_groups[ivertex] != face.smoothing_group # does the vertex already belong to a different smoothing group than that of the face given?
                push!(obj.vertices, copy(obj.vertices[ivertex]))
                face.vertices[i] 
            end
        end        
    end =#

    # compute normals per smoothing group
    for sgroup in obj.smoothing_groups
        ifaces = sgroup[2]

        # compute normal for each face
        face_normals = Array(Vector3{vertextype},length(ifaces))

        for (i, elem) in enumerate(ifaces)
            face = obj.faces[elem]
            e1 = obj.vertices[face.ivertices[2]] - obj.vertices[face.ivertices[1]]
            e2 = obj.vertices[face.ivertices[3]] - obj.vertices[face.ivertices[2]]

            n = unit(cross(e1,e2))
            face_normals[i] = n

            push!(obj.normals, n)
            face.inormals = [length(obj.normals),length(obj.normals),length(obj.normals)]
        end 

        # for each vertex, have an array of faces it belongs to
        #= vertex_faces = Dict()

        for i in faces
            face = faces[i]


            push!(collection, items...) -> collectio)
        end =#


        # for each vertex, take the average value over all faces

    end
end

# compile Obj
function compile{vertextype,faceindextype}(obj::WavefrontObjFile{vertextype,faceindextype})
    # change this copy&paste
    readfloat(x::FloatingPoint) = convert(vertextype, x)
    readfloat(x::String)        = parsefloat(vertextype, x)
    readint(x::String)          = parseint(faceindextype, x)
    readint(x::Integer)         = convert(faceindextype, x)

    vs_compiled  = Vector3{vertextype}[]
    nvs_compiled = Vector3{vertextype}[]
    uvs_compiled = Vector3{vertextype}[]
    vs_material_id = Uint8[]
    fcs_compiled = Vector3{faceindextype}[]

    i = 0
    for face in obj.faces
        push!(vs_compiled, obj.vertices[face.ivertices[1]])
        push!(vs_compiled, obj.vertices[face.ivertices[2]])
        push!(vs_compiled, obj.vertices[face.ivertices[3]])
        push!(vs_material_id, float32(findfirst(collect(keys(obj.materials)), face.material)))
        push!(vs_material_id, float32(findfirst(collect(keys(obj.materials)), face.material)))
        push!(vs_material_id, float32(findfirst(collect(keys(obj.materials)), face.material)))

        if isempty(face.inormals)
            println("WARNING: No normals!!!")
            push!(uvs_compiled, Vector3{vertextype}(0.0,0.0,0.0))
            push!(uvs_compiled, Vector3{vertextype}(0.0,0.0,0.0))
            push!(uvs_compiled, Vector3{vertextype}(0.0,0.0,0.0))
        else 
            push!(nvs_compiled, -obj.normals[face.inormals[1]])
            push!(nvs_compiled, -obj.normals[face.inormals[2]])
            push!(nvs_compiled, -obj.normals[face.inormals[3]])
        end

        if isempty(face.itexture_coords)
            push!(uvs_compiled, Vector3{vertextype}(0.0,0.0,0.0))
            push!(uvs_compiled, Vector3{vertextype}(0.0,0.0,0.0))
            push!(uvs_compiled, Vector3{vertextype}(0.0,0.0,0.0))
        else 
            push!(uvs_compiled, obj.tex_coords[face.itexture_coords[1]])
            push!(uvs_compiled, obj.tex_coords[face.itexture_coords[2]])
            push!(uvs_compiled, obj.tex_coords[face.itexture_coords[3]])
        end

        push!(fcs_compiled, Vector3{faceindextype}(readint(i), readint(i+1), readint(i+2)))
        i += 3
    end

    return (vs_compiled, nvs_compiled, uvs_compiled, vs_material_id, fcs_compiled)
end


##############################
#
# Mtl-Files
#
##############################

type WavefrontMtlMaterial{T}
    name::String
    ambient::Vector3{T}
    specular::Vector3{T}
    diffuse::Vector3{T}
    transmission_filter::Vector3{T}
    illum::Int
    dissolve::T
    specular_exponent::T
    ambient_texture::String
    specular_texture::String
    diffuse_texture::String
    bump_map::String
end

function WavefrontMtlMaterial(colortype=Float64)
    return WavefrontMtlMaterial{colortype}(
                "", 
                Vector3(zero(colortype)), 
                Vector3(zero(colortype)), 
                Vector3(zero(colortype)),
                Vector3(zero(colortype)), 
                0, 
                zero(colortype),
                zero(colortype),
                "",
                "",
                "",
                "" 
            )
end

function readMtlFile(fn::String; colortype=Float64)
    str = open(fn,"r")
    mesh = readMtlFile(str, colortype=colortype)
    close(str)
    return mesh
end

function parseMtlColor(s::String, colortype=Float64)
    colorconvfnc = colortype == Float64 ? float64 : (colortype == Float32 ? float32 : error("colortype: ", colortype, " not supported"))

    line_parts = split(s)

    if length(line_parts) == 3 # r b g
        return Vector3{colortype}(colorconvfnc(line_parts[1]), colorconvfnc(line_parts[2]), colorconvfnc(line_parts[3]))
    elseif line_parts[1] == "spectral" 
        println("WARNING Parsing Mtl-File: spectral color type not supported")
        return Vector3{colortype}(colorconvfnc(1.0), colorconvfnc(0.412), colorconvfnc(0.705))
    else
        println("WARNING Parsing Mtl-File: CIEXYZ color space or wrong color type. Not supported")
        return Vector3{colortype}(colorconvfnc(1.0), colorconvfnc(0.412), colorconvfnc(0.705))
    end
end

function parseMtlTextureMap(s::String)
    line_parts = split(s)

    if length(line_parts) == 1 # no options
        return line_parts[1]
    else
        println("WARNING Parsing Mtl-File: texture map options or invalid texutre map command. Not supported")
        return ""
    end
end

function readMtlFile(io::IO; colortype=Float64)
    colorconvfnc = colortype == Float64 ? float64 : (colortype == Float32 ? float32 : error("colortype: ", colortype, " not supported"))

    materials = WavefrontMtlMaterial{colortype}[]

    lineNumber = 1
    while !eof(io)
        # read a line, remove newline and leading/trailing whitespaces
        line = strip(chomp(readline(io)))
        @assert is_valid_ascii(line)

        if !beginswith(line, "#") && !isempty(line) && !iscntrl(line) #ignore comments
            line_parts = split(line)
            command = line_parts[1]
            remainder = length(line_parts) > 1 ? line[searchindex(line, line_parts[2]):end] : ""

            # new material
            if command == "newmtl" 
                push!(materials, WavefrontMtlMaterial(colortype))
                materials[end].name = line_parts[2]
            # abmient 
            elseif command == "Ka"
                materials[end].ambient = parseMtlColor(remainder, colortype)
            # diffuse
            elseif command == "Kd"
                materials[end].diffuse = parseMtlColor(remainder, colortype)
            # specular
            elseif command == "Ks"
                materials[end].specular = parseMtlColor(remainder, colortype)
            # transmission filter
            elseif command == "Tf"
                materials[end].transmission_filter = parseMtlColor(remainder, colortype)
            # illumination model
            elseif command == "illum"
                materials[end].illum = int(line_parts[2])
            # dissolve
            elseif command == "d"
                if line_parts[2] == "-halo"
                    println("WARNING Parsing Mtl-File: d -halo not supported")
                else
                    materials[end].dissolve = colorconvfnc(line_parts[2])
                end
            # specular exponent
            elseif command == "Ns"
                materials[end].specular_exponent = colorconvfnc(line_parts[2])
            # sharpness
            elseif command == "sharpness"
                println("WARNING Parsing Mtl-File: sharpness not supported")
            # optical density
            elseif command == "Ni"
                println("WARNING Parsing Mtl-File: optical density not supported")
            # ambient texture map
            elseif command == "map_Ka"
                materials[end].ambient_texture = parseMtlTextureMap(remainder)
            # diffuse texture map
            elseif command == "map_Kd"
                materials[end].diffuse_texture = parseMtlTextureMap(remainder)
            # specular texture map
            elseif command == "map_Ks"
                materials[end].specular_texture = parseMtlTextureMap(remainder)
            # specular exponent texture map
            elseif command == "map_Ns"
                println("WARNING Parsing Mtl-File: map_Ns not supported")
            # dissolve texture map
            elseif command == "map_d"
                println("WARNING Parsing Mtl-File: map_d not supported")
            # ???
            elseif command == "disp"
                println("WARNING Parsing Mtl-File: disp not supported")
            # ???
            elseif command == "decal"
                println("WARNING Parsing Mtl-File: decal not supported")
            # bump map
            elseif command == "bump"
                materials[end].bump_map = parseMtlTextureMap(remainder)   
            # ???
            elseif command == "refl"
                println("WARNING Parsing Mtl-File: refl not supported")
            # unknown line
            else 
                println("WARNING: Unknown line while parsing wavefront .mtl: '$line' (line $lineNumber)")
            end
        end

        # read next line
        lineNumber += 1
    end

    return materials
end

end # module
