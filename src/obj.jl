##############################
#
# obj-Files
#
##############################


add_format(format"OBJ", (), ".obj")

add_loader(format"OBJ", :GeometryTypes)

function load(fn::format"OBJ", MeshType=GLNormalMesh)
    io   = open(fn)
    mesh = load(io, typ)
    close(io)
    return mesh
end


#Default OBJ types
const WVO_ATTRIBUTES = Dict(
    "v"     => Point{3, Float32},
    "vn"    => Normal{3, Float32},
    "vt"    => UVW{Float32},
    "f"     => Face
)
#searches the mesh attributes for the corresponding obj attribute command
function get_attrib_type(mesh::Mesh, attrib::AbstractString)
    for (k,v) in attributes(typeof(mesh))
        if haskey(WVO_ATTRIBUTES, attrib)
            attribe_type = WVO_ATTRIBUTES[attrib] # returns an abstract type
            if eltype(v) <: attribe_type # match it against concrete attribute type from the mesh
                return eltype(v)
            end
        end
    end
    return nothing
end


function load{MT <: Mesh}(io::Stream{format"OBJ"}, MeshType::Type{MT}=GLNormalMesh)
    io           = stream(io)
    lineNumber   = 1
    mesh         = MeshType()
    last_command = ""
    attrib_type  = nothing
    for line in eachline(io)
        # read a line, remove newline and leading/trailing whitespaces
        line = strip(chomp(line))
        !isvalid(line) && error("non valid ascii in obj")

        if !startswith(line, "#") && !isempty(line) && !iscntrl(line) #ignore comments
            lines        = split(line)
            new_command  = shift!(lines) #first is the command, rest the data
            if last_command != new_command # cache the attrib_type lookup
                last_command = new_command
                attrib_type  = get_attrib_type(mesh, new_command)
            end
            attrib_type != nothing && process(attrib_type, lines, mesh, lineNumber) # only process if used by desired mesh type
        end
        # read next line
        lineNumber += 1
    end

    if isempty(mesh.normals) || length(mesh.normals) != length(mesh.vertices)
        empty!(mesh.normals)
        append!(mesh.normals, normals(mesh.vertices, mesh.faces))
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
process{V <: Point{3}, S <: AbstractString}(::Type{V}, lines::Vector{S}, mesh::Mesh, line::Int) =
    push_lines!(mesh.vertices, lines, line)

#Normals
process{N <: Normal{3}, S <: AbstractString}(::Type{N}, lines::Vector{S}, mesh::Mesh, line::Int) =
    push_lines!(mesh[N], lines, line)

#Texture coordinates
function process{TexCoord <: Union(UVW, UV), S <: AbstractString}(::Type{TexCoord}, lines::Vector{S}, mesh::Mesh, line::Int)
    length(lines) == 2 && push!(lines, "0.0") # length can be two, but obj normaly does three coordinates with the third equals 0.
    push_lines!(mesh[TexCoord], lines, line)
end

second(x)       = x[2]
third(x)        = x[3]
secondlast(x)   = x[end-1]
thirdlast(x)    = x[end-2]
immutable SplitFunctor <: Base.Func{1}
    seperator::ASCIIString
end
call(s::SplitFunctor, array) = split(array, s.seperator)

# of form "f v1 v2 v3 ....""
process_face{S <: AbstractString}(lines::Vector{S}) = (lines,) # just put it in the same format as the others
# of form "f v1//vn1 v2//vn2 v3//vn3 ..."
process_face_normal{S <: AbstractString}(lines::Vector{S}) = map(SplitFunctor("//"), lines)
# of form "f v1/vt1 v2/vt2 v3/vt3 ..." or of form "f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3 ...."
process_face_uv_or_normal{S <: AbstractString}(lines::Vector{S}) = map(SplitFunctor("/"), lines)

function process{F <: Face, S <: AbstractString}(::Type{F}, lines::Vector{S}, mesh::Mesh, line::Int)
    if any(x->contains(x, "/"), lines)
        faces = process_face_uv_or_normal(lines)
    elseif any(x->contains(x, "//"), lines)
        faces = process_face_normal(lines)
    else
        return push!(mesh[F], F(Triangle{Uint32}(lines)))
    end
    push!(mesh[F], F(Triangle{Uint32}(map(first, faces))))
end
