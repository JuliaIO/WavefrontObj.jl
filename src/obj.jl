##############################
#
# obj-Files
#
##############################




const WVO_ATTRIBUTES = @compat Dict(
    "v"     => Point3,
    "vn"    => Normal3,
    "vt"    => UVW,
    "f"     => Triangle
)
#searches the mesh attributes for the corresponding obj attribute command
function get_attrib_type(mesh::Mesh, attrib::AbstractString)
    for elem in attributelist(mesh)
        attribe_type = WVO_ATTRIBUTES[attrib] # returns an abstract type
        if elem <: attribe_type # match it against concrete attribute type from the mesh
            return elem
        end
    end
    return nothing
end


wvo_attribute(s::AbstractString) = WVO_ATTRIBUTES[s]


function Base.read(fn::File{:obj}, MeshType=GLNormalUVWMesh)
    fio = open(fn.abspath, "r")
    mesh = readobj(fio, MeshType)
    close(fio)
    return mesh
end

function readobj{MT <: Mesh}(io::IO, MeshType::Type{MT}=GLNormalUVWMesh)
    lineNumber  = 1
    mesh        = MeshType()
    for line in eachline(io)
        # read a line, remove newline and leading/trailing whitespaces
        line = strip(chomp(line))
        @assert is_valid_ascii(line) "non valid ascii in obj"

        if !startswith(line, "#") && !isempty(line) && !iscntrl(line) #ignore comments
            lines       = split(line)
            command     = shift!(lines) #first is the command, rest the data
            attrib_type = get_attrib_type(mesh, command)
            attrib_type != nothing && process(attrib_type, lines, mesh, lineNumber) # only process if used by desired mesh type
        end
        # read next line
        lineNumber += 1
    end
    return mesh
end


# face indices are allowed to be negative, this methods handles this correctly
function handle_index{T <: Integer}(bufferlength::Integer, s::AbstractString, index_type::Type{T})
    i = parseint(T, s)
    i < 0 && return convert(T, bufferlength) + i + one(T) # account for negative indexes
    return i
end
function push_index!{T}(buffer::Vector{T}, s::AbstractString)
    push!(buffer, handle_index(length(buffer), s, eltype(T)))
end

#=
#Unknown command -> just a warning for now
function process{S <: AbstractString}(::Any, lines::Vector{S}, mesh::Mesh, line::Int)
    println("WARNING: Unknown line while parsing wavefront obj: (line $line)")
end
=#

function push_lines!{T <: FixedVector, S <: AbstractString}(v::Vector{T}, lines::Vector{S}, line::Int)
    if length(lines) != length(T)
        error("Parse error in line $line. Length of attribute $T does not match found line. Line: $lines ")
    end
    push!(v, T(lines))
end
#Vertices
process{V <: Point3, S <: AbstractString}(::Type{V}, lines::Vector{S}, mesh::Mesh, line::Int) =
    push_lines!(vertices(mesh), lines, line)

#Normals
process{N <: Normal3, S <: AbstractString}(::Type{N}, lines::Vector{S}, mesh::Mesh, line::Int) =
    push_lines!(attributes(mesh)[N], lines, line)

#Texture coordinates
function process{TexCoord <: Union(UVW, UV), S <: AbstractString}(::Type{TexCoord}, lines::Vector{S}, mesh::Mesh, line::Int)
    length(lines) == 2 && push!(lines, "0.0") # length can be two, but obj normaly does three coordinates with the third equals 0.
    push_lines!(attributes(mesh)[TexCoord], lines, line)
end

process{F <: Triangle, S <: AbstractString}(::Type{F}, lines::Vector{S}, mesh::Mesh, line::Int) = 
    push_lines!(faces(mesh), lines, line)


#=
#Groups
function process{S <: AbstractString}(::Command{:g}, lines::Vector{S}, w::Mesh, line::Int)
    current_groups = AbstractString[]
    if length(lines) >= 2
        for i=2:length(lines)
            push!(current_groups, lines[i]) 
            if !haskey(groups, lines[i])
                groups[lines[i]] = Int[]
            end
        end
    else
        current_groups = ["default"]
    end
end
#Smoothing group
function process{S <: AbstractString}(::Command{:s}, lines::Vector{S}, w::WavefrontObjFile, line::Int)
    #smoothing group, 0 and off have the same meaning
    if lines[1] == "off" 
        current_smoothing_group = 0
    else
        current_smoothing_group = int(lines[2])
    end
    if !haskey(smoothing_groups, current_smoothing_group)
        smoothing_groups[current_smoothing_group] = Int[]
    end
end
# material lib reference
function process{S <: AbstractString}(::Command{:mtllib}, lines::Vector{S}, w::WavefrontObjFile, line::Int)
    for i=2:length(lines)
        push!(mtllibs, lines[i])
    end
end
# set a new material
function process{S <: AbstractString}(::Command{:usemtl}, lines::Vector{S}, w::WavefrontObjFile, line::Int)
    current_material = lines[2]
    if !haskey(materials, current_material)
        materials[current_material] = Int[]
    end
end
# faces:
#Faces are looking like this: f v1/vt1 v2/vt2 v3/vt3 ... OR f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3 .... OR f v1//vn1 v2//vn2 v3//vn3 ...
# Triangles:
function process{Cardinality, S <: AbstractString}(::Command{:f}, lines::AbstractFixedVector{Cardinality, S}, w::WavefrontObjFile, line::Int)
    # inside faceindex, the coordinates looke like this: #/# or #/#/# or #//#. The first entry determines the type for all following entries
    seperator = contains(lines, "//") ? "//" : contains(lines, "/") ? "/" : error("unknown face seperator")
    face      = map(part -> split(part, seperator), lines)
    lp        = length(first(face))
    @assert lp >= 1 && lp <= 3 "Obj's should only allow for three vertex attributes. Attributes found: $(length(v)) in line $line"

    # 
    lp >= 1 && push_index!(w.vertex_index,             face[1])
    lp >= 2 && push_index!(w.texture_coordinate_index, face[2])
    lp == 3 && push_index!(w.normal_index,             face[3])
    # add face to groups, smoothing_group,
    for group in current_groups
        push!(groups[group], length(fcs)+1) 
    end

    push!(materials[current_material], length(fcs)+1)

    push!(smoothing_groups[current_smoothing_group], length(fcs)+1)

    push!(fcs, face)
end

# smoothing groups: "off" goes to smoothing group 0, so each face has a unique smoothing group
# faces with no material go to the empty material "", so each face has a unique material
=#