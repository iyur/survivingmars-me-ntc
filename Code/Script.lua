if IsDlcAccessible("prunariu") then 

	function TrackConstructionController:UpdateVisuals(pt, input_points)
	  local q, r = WorldToHex(pt)
	  local hex_pos = point(q, r)
	  if self.last_update_hex and hex_pos == self.last_update_hex then
	    return
	  end
	  self.last_update_hex = hex_pos
	  ObjModified(self)
	  local old_t = self.construction_statuses
	  self.construction_statuses = {}
	  local game_map = GetGameMap(self)
	  local object_hex_grid = game_map.object_hex_grid
	  RefreshStationSigns(self.starting_point and pt, object_hex_grid)
	  if not self.starting_point then
	    local result, reason, _ = self:CanExtendFrom(pt)
	    if not result then
	      if reason == "no_station" then
	        table.insert(self.construction_statuses, ConstructionStatus.TrackRequiresTwoStations)
	      else
	        table.insert(self.construction_statuses, ConstructionStatus.BlockingObjects)
	      end
	      if self.cursor_obj then
	        if not self.template_obj then
	          self.template_obj = ClassTemplates.Building.Passage
	          self.is_template = true
	          self.template_obj_points = FallbackOutline
	        end
	        self:UpdateConstructionObstructors(self)
	        self:SetColorToAllConstructionObstructors(g_PlacementStateToColor.Obstructing)
	      end
	      if self.cursor_obj then
	        self.cursor_obj:SetColorModifier(g_PlacementStateToColor.Blocked)
	      end
	    elseif self.cursor_obj then
	      if not DoesAnyDroneControlServiceAtPoint(game_map.map_id, pt) then
	        table.insert_unique(self.construction_statuses, ConstructionStatus.NoDroneHub)
	        self.cursor_obj:SetColorModifier(g_PlacementStateToColor.Problematic)
	      else
	        self.cursor_obj:SetColorModifier(const.clrNoModifier)
	      end
	      self:ClearColorFromAllConstructionObstructors()
	      self:ClearDomeWithObstructedRoads()
	    end
	    if not table.iequals(old_t, self.construction_statuses) then
	      ObjModified(self)
	    end
	    self:UpdateShortConstructionStatus()
	    return
	  end
	  local pt_arr = self.placed_points or nil
	  local sp = pt_arr and pt_arr[#pt_arr] or self.starting_point
	  pt = pt:SetInvalidZ()
	  local points
	  if input_points then
	    points = input_points
	  else
	    points = {
	      HexClampToAxis(sp, pt)
	    }
	    local number_of_lines = points[1] == pt and 1 or 2
	    if 1 < number_of_lines then
	      points = self:GetDoubleLinePoints(pt, sp)
	    end
	  end
	  local points_prestine = points
	  if pt_arr then
	    points = table.iappend(table.copy(pt_arr), points)
	  end
	  local total_len = 0
	  local prev_point = points[1]
	  local start_idx = 2
	  local last_angle = -1
	  local start_station = false
	  local steps_arr = {}
	  local clr = const.clrNoModifier
	  local all_obstructors = {}
	  local all_data = {}
	  local all_rocks = {}
	  local can_constr_final = true
	  local terrain = game_map.terrain
	  for i = start_idx, #points do
	    local next_point = points[i]
	    next_point = next_point and next_point:SetZ(terrain:GetHeight(next_point)) or false
	    if not next_point or next_point:Equal2D(prev_point) and i > start_idx then
	      prev_point = next_point
	    else
	      local len = prev_point:Dist2D(next_point)
	      local steps = (len + const.GridSpacing / 2) / const.GridSpacing
	      local max_steps = self.max_hex_distance_to_allow_build - 1 - (steps_arr[i - 1] or 0)
	      local end_pos = next_point
	      local fbreak = false
	      if not end_pos:Equal2D(prev_point) then
	        local a = CalcOrientation(prev_point, end_pos)
	        local na = abs(AngleDiff(a, last_angle))
	        if 0 <= last_angle and 3600 < na then
	          if #all_data < self.max_hex_distance_to_allow_build then
	            table.insert(self.construction_statuses, ConstructionStatus.PassageAngleToSteep)
	          end
	          fbreak = true
	        end
	        last_angle = a
	      end
	      if max_steps <= 0 or fbreak then
	        points[i] = nil
	        steps_arr[i] = nil
	        break
	      elseif steps > max_steps then
	        end_pos = prev_point + MulDivRound(next_point - prev_point, max_steps, steps)
	        steps = max_steps
	      end
	      points[i] = end_pos
	      steps_arr[i] = steps
	      local can_constr, _, obstructors, data, _, axial_dist, rocks = self:CanConstructLine(prev_point, end_pos, steps, all_data)
	      all_rocks[i] = rocks
	      if obstructors then
	        table.iappend_unique(all_obstructors, obstructors)
	      end
	      if i > start_idx and 0 < #data then
	        data[0].is_turn = true
	        table.remove(all_data)
	      end
	      for j = 0, #data do
	        all_data[#all_data + 1] = data[j]
	      end
	      for k, v in pairs(data) do
	        if type(k) == "string" then
	          all_data[k] = v
	        end
	      end
	      total_len = total_len + (axial_dist or 0)
	      can_constr_final = can_constr_final and can_constr
	      prev_point = next_point
	      if not start_station and 0 < #all_data then
	        start_station = all_data[1].bld
	      end
	    end
	  end
	  local data_count = #all_data
	  local last_idx = Min(data_count, self.max_hex_distance_to_allow_build)
	  if last_idx <= 0 then
	    return
	  end
	  if not can_constr_final then
	    clr = g_PlacementStateToColor.Blocked
	  end
	  if all_data[data_count].bld == start_station then
	    table.insert(self.construction_statuses, ConstructionStatus.TrackRequiresDifferentStations)
	    clr = g_PlacementStateToColor.Blocked
	  end
	  if clr == const.clrNoModifier then
	    local obstructor_count = #all_obstructors
	    if 2 < obstructor_count or obstructor_count == 2 and (all_data[1].status == SupplyGridElementHexStatus.clear or all_data[data_count].status == SupplyGridElementHexStatus.clear) or obstructor_count == 1 and all_data[1].status == SupplyGridElementHexStatus.clear and all_data[data_count].status == SupplyGridElementHexStatus.clear or all_obstructors[1] == g_DontBuildHere then
	      clr = g_PlacementStateToColor.Blocked
	    end
	  end
	  local n = all_data[last_idx]
	  local end_connected = IsPointStationTrackConnection(object_hex_grid, n.q, n.r)
	  if not end_connected then
	    table.insert(self.construction_statuses, ConstructionStatus.TrackRequiresTwoStations)
	  end
	  if 1 < last_idx then
	    if not IsPointStationTrackDirection(object_hex_grid, all_data[2].q, all_data[2].r, all_data[1].q, all_data[1].r) then
	      table.insert(self.construction_statuses, ConstructionStatus.WrongTrackDirection)
	    elseif end_connected and not IsPointStationTrackDirection(object_hex_grid, all_data[last_idx - 1].q, all_data[last_idx - 1].r, n.q, n.r) then
	      table.insert(self.construction_statuses, ConstructionStatus.WrongTrackDirection)
	    end
	  end
	  -- if 3 <= last_idx then
	  --   for idx1 = 3, last_idx - 1 do
	  --     for idx2 = 2, idx1 - 1 do
	  --       if all_data[idx1].q == all_data[idx2].q and all_data[idx1].r == all_data[idx2].r then
	  --         table.insert(self.construction_statuses, ConstructionStatus.BlockingObjects)
	  --         break
	  --       end
	  --     end
	  --   end
	  -- end
	  for idx = last_idx - 1, 2, -1 do
	    if not IsTrackElementStraight(all_data[idx]) and 2 < idx and not IsTrackElementStraight(all_data[idx - 1]) then
	      table.insert(self.construction_statuses, ConstructionStatus.TrackCurvesTooClose)
	      break
	    end
	  end
	  SetPillars(all_data)
	  for i = 1, last_idx do
	    local data = all_data[i]
	    if data.pillared then
	      local bld = HexGetBuilding(object_hex_grid, data.q, data.r)
	      if IsKindOf(bld, "PassageGridElement") then
	        table.insert_unique(all_obstructors, bld)
	        table.insert(self.construction_statuses, ConstructionStatus.BlockingObjects)
	      end
	    end
	  end
	  if clr ~= const.clrNoModifier and next(all_obstructors) then
	    table.insert(self.construction_statuses, ConstructionStatus.BlockingObjects)
	  end
	  all_rocks[1] = all_rocks[1] or {}
	  local rt = {}
	  for i = 1, #all_rocks do
	    rt = table.iappend(rt, all_rocks[i])
	  end
	  all_rocks = rt
	  self:ColorRocks(all_rocks)
	  self:ClearColorFromMissingConstructionObstructors(self.construction_obstructors, all_obstructors)
	  self.construction_obstructors = all_obstructors
	  self:SetColorToAllConstructionObstructors(g_PlacementStateToColor.Obstructing)
	  local visuals = self.visuals
	  local visuals_idx = 1
	  local last_visual_element = false
	  local last_visual_node = false
	  local did_start = false
	  local x, y, z
	  z = const.InvalidZ
	  local angle = CalcOrientation(self.starting_point, points[1])
	  local passed_block_reasons = {}
	  if all_data.has_group_with_no_hub then
	    table.insert_unique(self.construction_statuses, ConstructionStatus.NoDroneHub)
	  end
	  for i = 1, last_idx do
	    local node = all_data[i]
	    local reason = node.block_reason
	    if reason and not passed_block_reasons[reason] then
	      if reason == "roads" then
	        table.insert_unique(self.construction_statuses, ConstructionStatus.NonBuildableInterior)
	      elseif reason == "block_entrance" then
	        table.insert_unique(self.construction_statuses, ConstructionStatus.PassageTooCloseToEntrance)
	      elseif reason == "block_life_support" then
	        table.insert_unique(self.construction_statuses, ConstructionStatus.PassageTooCloseToLifeSupport)
	      -- elseif reason == "unbuildable" then
	      --   table.insert_unique(self.construction_statuses, ConstructionStatus.UnevenTerrain)
	      elseif reason == "no_hub" then
	        table.insert_unique(self.construction_statuses, ConstructionStatus.NoDroneHub)
	      end
	      passed_block_reasons[reason] = true
	    end
	  end
	  SortConstructionStatuses(self.construction_statuses)
	  local s = self:GetConstructionState()
	  if s == "error" and clr ~= g_PlacementStateToColor.Blocked then
	    clr = g_PlacementStateToColor.Blocked
	  elseif s == "problem" and clr ~= g_PlacementStateToColor.Problematic then
	    clr = g_PlacementStateToColor.Problematic
	  end
	  self:UpdateShortConstructionStatus(all_data[data_count])
	  local buildable = game_map.buildable
	  for i = 1, last_idx do
	    local node = all_data[i]
	    if node.is_turn then
	      angle = CalcOrientation(points[1], points[2])
	    end
	    if clr == g_PlacementStateToColor.Blocked or node.status < SupplyGridElementHexStatus.blocked then
	      x, y = HexToWorld(node.q, node.r)
	      local el = visuals.elements[visuals_idx]
	      local buildable_z = buildable:GetZ(node.q, node.r)
	      el:SetPos(x, y, buildable_z ~= UnbuildableZ and buildable_z or z)
	      if i == 1 then
	        z = el:GetPos():z()
	      end
	      el:SetColorModifier(clr)
	      el:SetAngle(angle % 10800)
	      rawset(el, "node", node)
	      visuals_idx = visuals_idx + 1
	      local e = GetTrackEntity(node)
	      local a = GetTrackAngle(node)
	      if a ~= el:GetAngle() then
	        el:SetAngle(a)
	      end
	      if not did_start then
	        did_start = true
	        e = "TrackPillarCCP3"
	      end
	      if e ~= el:GetEntity() then
	        el:DestroyAttaches()
	        el:ChangeEntity(e)
	        AutoAttachObjectsToPlacementCursor(el)
	        el:ForEachAttach(function(attach)
	          attach:SetSIModulation(0)
	        end)
	      end
	      el:SetVisible(true)
	      last_visual_node = node
	      last_visual_element = el
	    end
	  end
	  local el = visuals.elements[visuals_idx - 1]
	  if el then
	    self:SetTxtPosObj(el)
	  end
	  for i = visuals_idx, self.max_hex_distance_to_allow_build do
	    visuals.elements[i]:SetVisible(false)
	  end
	  self.current_points = points_prestine
	  self.current_status = clr
	  self.current_len = data_count
	  ObjModified(self)
	end

function PlaceTrackLine(city, start_q, start_r, dir, steps, test, elements_require_construction, input_constr_grp, input_data, entrance_hexes)
  local dq, dr = HexNeighbours[dir + 1]:xy()
  local angle = dir * 60 * 60
  local construction_group = false
  if not test and elements_require_construction or input_constr_grp then
    if input_constr_grp then
      construction_group = input_constr_grp
    else
      construction_group = CreateConstructionGroup("TrackGridElement", point(HexToWorld(start_q, start_r)), city:GetMapID(), 3, not elements_require_construction)
    end
  end
  local clean_group = function(construction_group)
    if construction_group and construction_group[1]:CanDelete() then
      DoneObject(construction_group[1])
      construction_group = false
    end
    return construction_group
  end
  local last_status = false
  local last_placed_data_cell
  local last_pass_idx = 0
  local total_data_count = 0
  local has_group_with_no_hub = true
  if input_data and (0 < #input_data or input_data[0]) then
    last_placed_data_cell = input_data[#input_data]
    last_pass_idx = last_placed_data_cell.idx
    last_status = last_placed_data_cell.status
    local decrement = input_data[0] and 1 or 0
    total_data_count = #input_data + decrement
    steps = Min(const.TrackConstructionGroupMaxSize - total_data_count, steps)
    total_data_count = total_data_count - 1
    has_group_with_no_hub = input_data.has_group_with_no_hub
  end
  local data = {}
  local obstructors = {}
  local all_rocks = {}
  local can_build_anything = true
  local surf_deps_filter = function(obj)
    return not table.find(obstructors, obj)
  end
  local stockpile_filter = function(obj)
    return obj:GetParent() == nil and IsKindOf(obj, "DoesNotObstructConstruction") and not IsKindOf(obj, "Unit")
  end
  local build_connections = function(data_idx, ret)
    ret = ret or {}
    local build_connection = function(idx, ret)
      if data[idx] then
        local cell = data[idx]
        table.insert(ret, {
          q = cell.q,
          r = cell.r
        })
        return true
      end
      return false
    end
    local prev_idx = data_idx - 1
    if build_connection(prev_idx, ret) then
      build_connection(data_idx, data[prev_idx].connections)
    end
    return ret
  end
  local game_map = GetGameMap(city)
  local object_hex_grid = game_map.object_hex_grid
  local terrain = game_map.terrain
  local buildable = game_map.buildable
  local realm = game_map.realm
  for i = 0, steps do
    local q = start_q + i * dq
    local r = start_r + i * dr
    local bld = HexGetBuildingNoDome(object_hex_grid, q, r)
    local passage = bld and (IsKindOf(bld, "PassageGridElement") or IsKindOf(bld, "PassageConstructionSite"))
    local entrance = GetEntranceHex(entrance_hexes, q, r)
    local cable = HexGetCable(object_hex_grid, q, r)
    local pipe = HexGetPipe(object_hex_grid, q, r)
    local dome = GetDomeAtHex(object_hex_grid, q, r)
    local world_pos = point(HexToWorld(q, r))
    local is_buildable = buildable:IsBuildableZone(world_pos)
    local surf_deps = is_buildable and HexGetUnits(realm, nil, nil, world_pos, 0, nil, surf_deps_filter, "SurfaceDeposit") or empty_table
    local anomalies = is_buildable and HexGetUnits(realm, nil, nil, world_pos, 0, nil, surf_deps_filter, "SubsurfaceAnomaly") or empty_table
    local rocks = is_buildable and HexGetUnits(realm, nil, nil, world_pos, 0, false, nil, "WasteRockObstructor") or empty_table
    table.iappend(all_rocks, rocks)
    local stockpiles = is_buildable and HexGetUnits(realm, nil, nil, world_pos, 0, false, stockpile_filter, "ResourceStockpileBase") or empty_table
    if i == 0 and last_placed_data_cell ~= nil then
      data[i] = last_placed_data_cell
      bld = data[i].bld
    else
      data[i] = {
        q = q,
        r = r,
        status = SupplyGridElementHexStatus.clear,
        cable = cable,
        rocks = rocks,
        stockpiles = stockpiles,
        pipe = pipe,
        idx = last_pass_idx + i,
        bld = bld
      }
    end
    if has_group_with_no_hub and DoesAnyDroneControlServiceAtPoint(game_map.map_id, world_pos) then
      has_group_with_no_hub = false
    end
    data[i].place_construction_site = elements_require_construction or 0 < #rocks or 0 < #stockpiles
    data[i].connections = build_connections(i, data[i].connections)
    if bld and not passage and (i ~= 0 and i ~= steps or not IsPointStationTrackConnection(object_hex_grid, q, r)) then
      table.insert(obstructors, bld)
      data[i].status = SupplyGridElementHexStatus.blocked
    end
    if entrance then
      table.insert(obstructors, entrance)
      data[i].status = SupplyGridElementHexStatus.blocked
      data[i].block_reason = "block_entrance"
    end
    if dome then
      table.insert(obstructors, dome)
      data[i].status = SupplyGridElementHexStatus.blocked
    end
    if test then
      local dq = {
        0,
        -1,
        -1,
        0,
        0,
        1,
        1
      }
      local dr = {
        0,
        0,
        1,
        -1,
        1,
        -1,
        0
      }
      -- for k = 1, 7 do
      --   local other_track = object_hex_grid:GetObject(q + dq[k], r + dr[k], "TrackGridElement")
      --   if test and other_track then
      --     table.insert(obstructors, other_track)
      --     data[i].status = SupplyGridElementHexStatus.blocked
      --   end
      -- end
    end
    if pipe and pipe.pillar then
      table.insert(obstructors, pipe)
      data[i].status = SupplyGridElementHexStatus.blocked
    end
    if surf_deps and 0 < #surf_deps then
      table.iappend(obstructors, surf_deps)
      data[i].status = SupplyGridElementHexStatus.blocked
    end
    if anomalies and 0 < #anomalies then
      table.iappend(obstructors, anomalies)
      data[i].status = SupplyGridElementHexStatus.blocked
    end
    -- if not is_buildable then
    --   data[i].status = SupplyGridElementHexStatus.unbuildable
    --   data[i].block_reason = "unbuildable"
    -- end
    if can_build_anything and data[i].status ~= SupplyGridElementHexStatus.clear then
      can_build_anything = false
    end
    total_data_count = total_data_count + 1
    last_status = data[i].status
  end
  local total_cost = GetTrackConstructionCost(total_data_count)
  data.has_group_with_no_hub = has_group_with_no_hub
  if test or not can_build_anything then
    construction_group = clean_group(construction_group)
    return can_build_anything, construction_group, obstructors, data, all_rocks, nil, total_cost
  end
  local first_obj_z = input_data and input_data.first_obj_z or false
  local track_obj = input_data and input_data.track_obj or PlaceObjectIn("Track", game_map.map_id, {})
  local place_track_cs = function(terrain, data_idx, cg)
    local params = {}
    local cell_data = data[data_idx]
    if cell_data.element then
      return cell_data.element
    end
    local q = cell_data.q
    local r = cell_data.r
    params.construction_group = cg
    cg[#cg + 1] = params
    params.q = q
    params.r = r
    params.station = IsKindOf(cell_data.bld, "Station") and cell_data.bld
    params.pillared = cell_data.pillared
    params.connections = cell_data.connections
    params.track_obj = track_obj
    track_obj.last_node_idx = track_obj.last_node_idx + 1
    params.node_idx = track_obj.last_node_idx
    local pos = point(HexToWorld(q, r))
    if not first_obj_z then
      pos = FixConstructPos(terrain, pos)
      first_obj_z = pos:z()
    else
      pos = pos:SetZ(first_obj_z)
    end
    local cs = PlaceConstructionSite(city, "TrackGridElement", pos, angle, params)
    cs:AppendWasteRockObstructors(cell_data.rocks)
    cs:AppendStockpilesUnderneath(cell_data.stockpiles)
    cell_data.element = cs
    return cs
  end
  local place_track = function(data_idx)
    local cell_data = data[data_idx]
    if cell_data.element then
      return cell_data.element
    end
    local q = cell_data.q
    local r = cell_data.r
    track_obj.last_node_idx = track_obj.last_node_idx + 1
    local el = TrackGridElement:new({
      city = city,
      q = q,
      r = r,
      station = cell_data.bld,
      connections = cell_data.connections,
      track_obj = track_obj,
      node_idx = track_obj.last_node_idx
    }, city:GetMapID())
    local x, y = HexToWorld(q, r)
    local z = first_obj_z or terrain:GetHeight(x, y)
    first_obj_z = first_obj_z or z
    el:SetPos(x, y, z)
    el:SetAngle(angle)
    el:SetGameFlags(const.gofPermanent)
    if not cell_data.station then
      FlattenTerrainInBuildShape(nil, el)
    end
    cell_data.element = el
    return el
  end
  local i = 0
  local last_placed_obj
  while steps >= i do
    local cell_data = data[i]
    local q = cell_data.q
    local r = cell_data.r
    if data[i].status == SupplyGridElementHexStatus.clear then
      local placed = false
      if cell_data.place_construction_site then
        if not construction_group or #construction_group > const.TrackConstructionGroupMaxSize then
          if construction_group and construction_group[1]:CanDelete() then
            DoneObject(construction_group[1])
          end
          construction_group = false
          if elements_require_construction or 0 < #data[i].rocks or 0 < #data[i].stockpiles then
            construction_group = CreateConstructionGroup("TrackGridElement", point(HexToWorld(q, r)), city:GetMapID(), 3, not elements_require_construction)
          end
        end
        if construction_group then
          last_placed_obj = place_track_cs(terrain, i, construction_group)
          placed = last_placed_obj
        end
      end
      if not placed then
        last_placed_obj = place_track(i)
      end
    end
    if last_placed_obj and #track_obj.elements + #track_obj.elements_under_construction == 1 then
      track_obj.start_el = last_placed_obj
    end
    i = i + 1
  end
  construction_group = clean_group(construction_group)
  if track_obj:CanDelete() then
    DoneObject(track_obj)
  else
    data.track_obj = track_obj
    data.first_obj_z = first_obj_z
    track_obj.end_el = last_placed_obj
    if not track_obj:IsValidPos() then
      track_obj:SetPos(data[0].element:GetPos())
    end
    if construction_group then
      construction_group[1].construction_cost_multiplier = not elements_require_construction and 0 or (#construction_group - 1) * 100
      local profile = g_CurrentMissionParams and g_CurrentMissionParams.idCommanderProfile
      if profile == "TransportTycoon" then
        construction_group[1].construction_cost_multiplier = DivRound(construction_group[1].construction_cost_multiplier, 2)
      end
    end
  end
  return true, construction_group, obstructors, data, last_placed_obj, nil, total_cost
end

end