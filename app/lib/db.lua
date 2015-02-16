--[[

Mid Level Storage Commands
=========================

These commands work at a higher level and consume the low-level storage APIs.

db.load(hash) -> kind, value           - error if not found
db.loadAs(kind, hash) -> value         - error if not found or wrong type
db.save(kind, value) -> hash           - encode and save to objects/$ha/$sh
db.hashes() -> iter                    - Iterate over all hashes

db.read(author, tag, version) -> hash  - Read from refs/tags/$author/$tag/v$version
db.write(author, tag, version, hash)   - Write to refs/tags/$suthor/$tag/v$version
db.authors() -> iter                   - Iterate over refs/tags/*
db.tags(author) -> iter                - Iterate nodes in refs/tags/$author/**
db.versions(author, tag) -> iter       - Iterate leaves in refs/tags/$author/$tag/*

db.readKey(author, fingerprint) -> key - Read from keys/$author/$fingerprint
db.putKey(author, fingerprint, key)    - Write to keys/$author/$fingerprint
db.revokeKey(author, fingerprint)      - Delete keys/$author/$fingerprint
db.fingerprints(author) -> iter        - iter of fingerprints

db.getEtag(author) -> etag             - Read keys/$author.etag
db.setEtag(author, etag)               - Writes keys/$author.etag

db.owners(org) -> iter                 - Iterates lines of keys/$org.owners
db.isOwner(org, author) -> bool        - Check if a user is an org owner
db.addOwner(org, author)               - Add a new owner
db.removeOwner(org, author)            - Remove an owner

db.import(path) -> kind, hash          - Import a file or tree into database
db.export(hash, path) -> kind          - Export a hash to a path
]]

return function (path)
  local storage = require('./storage')(path)
  local semver = require('semver')
  local normalize = semver.normalize
  local digest = require('openssl').digest.digest
  local deflate = require('miniz').deflate
  local inflate = require('miniz').inflate
  local pathJoin = require('luvi').path.join
  local fs = require('coro-fs')
  local git = require('git')
  local decoders = git.decoders
  local encoders = git.encoders
  local deframe = git.deframe
  local frame = git.frame
  local modes = git.modes

  local db = {}

  local function assertHash(hash)
    assert(hash and #hash == 40 and hash:match("^%x+$"), "Invalid hash")
  end

  local function hashPath(hash)
    return string.format("objects/%s/%s", hash:sub(1, 2), hash:sub(3))
  end

  function db.load(hash)
    assertHash(hash)
    local compressed, err = storage.read(hashPath(hash))
    if not compressed then return nil, err end
    local kind, raw = deframe(inflate(compressed, 1))
    return kind, decoders[kind](raw)
  end

  function db.loadAs(kind, hash)
    assertHash(hash)
    local actualKind, value = db.load(hash)
    assert(kind == actualKind, "Kind mismatch")
    return value
  end

  function db.save(kind, value)
    if type(value) ~= "string" then
      value = encoders[kind](value)
    end
    local framed = frame(kind, value)
    local hash = digest("sha1", framed)
    -- 0x1000 = TDEFL_WRITE_ZLIB_HEADER
    -- 4095 = Huffman+LZ (slowest/best compression)
    storage.put(hashPath(hash), deflate(framed, 0x1000 + 4095))
    return hash
  end

  function db.hashes()
    local groups = storage.nodes("objects")
    local prefix, iter
    return function ()
      while true do
        if prefix then
          local rest = iter()
          if rest then return prefix .. rest end
          prefix = nil
          iter = nil
        end
        prefix = groups()
        if not prefix then return end
        iter = storage.leaves("objects/" .. prefix)
      end
    end
  end

  function db.match(author, tag, version)
    local match = semver.match(version, db.versions(author, tag))
    if not match then return end
    return match, assert(db.read(author, tag, match))
  end

  function db.read(author, tag, version)
    version = normalize(version)
    local path = string.format("refs/tags/%s/%s/v%s", author, tag, version)
    local hash = storage.read(path)
    if not hash then return end
    return hash:sub(1, 40)
  end

  function db.write(author, tag, version, hash)
    version = normalize(version)
    assertHash(hash)
    local path = string.format("refs/tags/%s/%s/v%s", author, tag, version)
    storage.write(path, hash .. "\n")
  end

  function db.authors()
    return storage.nodes("refs/tags")
  end

  function db.tags(author)
    local prefix = "refs/tags/" .. author .. "/"
    local stack = {storage.nodes(prefix)}
    return function ()
      while true do
        if #stack == 0 then return end
        local tag = stack[#stack]()
        if tag then
          local path = stack[#stack - 1]
          local newPath = path and path .. "/" .. tag or tag
          stack[#stack + 1] = newPath
          stack[#stack + 1] = storage.nodes(prefix .. newPath)
          return newPath
        end
        stack[#stack] = nil
        stack[#stack] = nil
      end
    end
  end

  function db.versions(author, tag)
    local path = string.format("refs/tags/%s/%s", author, tag)
    return storage.leaves(path)
  end

  local function keyPath(author, fingerprint)
    return string.format("keys/%s/%s", author, fingerprint)
  end

  function db.readKey(author, fingerprint)
    return storage.read(keyPath(author, fingerprint))
  end

  function db.putKey(author, fingerprint, key)
    return storage.put(keyPath(author, fingerprint), key)
  end

  function db.revokeKey(author, fingerprint)
    return storage.delete(keyPath(author, fingerprint))
  end

  function db.fingerprints(author)
    return storage.leaves("keys/" .. author)
  end

  function db.getEtag(author)
    return storage.read("keys/" .. author .. ".etag")
  end

  function db.setEtag(author, etag)
    return storage.write("keys/" .. author .. ".etag", etag)
  end

  local function ownersPath(org)
    return "keys/" .. org .. ".owners"
  end

  function db.owners(org)
    local owners = storage.read(ownersPath(org))
    if not owners then
      return function() end
    end
    return owners:gmatch("[^\n]+")
  end

  function db.isOwner(org, author)
    for owner in db.owners(org) do
      if author == owner then return true end
    end
    return false
  end

  function db.addOwner(org, author)
    if db.isOwner(org, author) then return end
    local path = ownersPath(org)
    local owners = storage.read(path)
    owners = (owners or "") .. author .. "\n"
    storage.write(path, owners)
  end

  function db.removeOwner(org, author)
    local list = {}
    for owner in db.owners(org) do
      if owner ~= author then
        list[#list + 1] = owner
      end
    end
    storage.write(ownersPath(org), table.concat(list, "\n") .. "\n")
  end

  local importEntry, importTree

  function importEntry(path, stat)
    if stat.type == "directory" then
      return modes.tree, importTree(path)
    end
    if stat.type == "file" then
      stat = stat.mode and stat or fs.stat(path)
      local mode = bit.band(stat.mode, 73) > 0 and modes.exec or modes.file
      return mode, db.save("blob", assert(fs.readFile(path)))
    end
    if stat.type == "link" then
      return modes.sym, db.save("blob", assert(fs.readlink(path)))
    end
    error("Unsupported type at " .. path .. ": " .. stat.type)
  end

  function importTree(path)
    local items = {}
    for entry in assert(fs.scandir(path)) do
      if string.sub(entry.name, 1, 1) ~= '.' and entry.name ~= "modules" then
        local fullPath = pathJoin(path, entry.name)
        entry.mode, entry.hash = importEntry(fullPath, entry)
        items[#items + 1] = entry
      end
    end
    return db.save("tree", items)
  end

  function db.import(path)
    local mode, hash = importEntry(path, assert(fs.stat(path)))
    return modes.toType(mode), hash
  end

  local exportEntry, exportTree

  function exportEntry(path, mode, value)
    if mode == modes.tree then
      exportTree(path, value)
    elseif mode == modes.sym then
      local success, err = fs.symlink(value, path)
      if not success and err:match("^ENOENT:") then
        assert(fs.mkdirp(pathJoin(path, "..")))
        assert(fs.symlink(value, path))
      end
    elseif modes.isFile(mode) then
      local success, err = fs.writeFile(path, value)
      if not success and err:match("^ENOENT:") then
        assert(fs.mkdirp(pathJoin(path, "..")))
        assert(fs.writeFile(path, value))
      end
      assert(fs.chmod(path, mode))
    else
      error("Unsupported mode at " .. path .. ": " .. mode)
    end
  end

  function exportTree(path, tree)
    assert(fs.mkdirp(path))
    for i = 1, #tree do
      local entry = tree[i]
      local newPath = pathJoin(path, entry.name)
      local kind, value = db.load(entry.hash)
      assert(modes.toType(entry.mode) == kind, "Git kind mismatch")
      exportEntry(newPath, entry.mode, value)
    end
  end

  function db.export(hash, path)
    local kind, value = db.load(hash)
    if not kind then error(value or "No such hash") end
    exportEntry(path, kind == "tree" and modes.tree or modes.blob, value)
    return kind
  end

  return db
end
