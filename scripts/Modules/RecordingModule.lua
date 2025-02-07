ADRecordingModule = {}

function ADRecordingModule:new(vehicle)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.vehicle = vehicle
    if not vehicle.ad.ADLeftNode then
        vehicle.ad.ADLeftNode = createTransformGroup("ADLeftNode")
        link(vehicle.rootNode, vehicle.ad.ADLeftNode)
        setRotation(vehicle.ad.ADLeftNode, 0, 0, 0)
        setTranslation(vehicle.ad.ADLeftNode, 0, 0, 0)
        vehicle.ad.ADRightNode = createTransformGroup("ADRightNode")
        link(vehicle.rootNode, vehicle.ad.ADRightNode)
        setRotation(vehicle.ad.ADRightNode, 0, 0, 0)
        setTranslation(vehicle.ad.ADRightNode, 0, 0, 0)
    end
    ADRecordingModule.reset(o)
    return o
end

function ADRecordingModule:reset()
    self.isSubPrio = false
    self.trailerCount = 0
    self.isSubPrio = false
    self.flags = 0
    self.isRecording = false
    self.isRecordingReverse = false
    self.drivingReverse = false
    self.isDual = false
    self.lastWp = nil
    self.secondLastWp = nil
    self.lastWp2 = nil -- 2 road recording
    self.secondLastWp2 = nil -- 2 road recording
    self.isRecordingTwoRoads = false
end

function ADRecordingModule:start(dual, subPrio)
    self.isDual = dual
    self.isSubPrio = subPrio
    self.vehicle:stopAutoDrive()
    self.isRecordingTwoRoads = AutoDrive.getSetting("RecordTwoRoads") ~= 0
    if self.isRecordingTwoRoads and self.vehicle.ad.ADLeftNode then
        setTranslation(self.vehicle.ad.ADLeftNode, AutoDrive.getSetting("RecordTwoRoads"), 0, 0)
        setTranslation(self.vehicle.ad.ADRightNode, -AutoDrive.getSetting("RecordTwoRoads"), 0, 0)
        AutoDriveMessageEvent.sendNotification(self.vehicle, ADMessagesManager.messageTypes.INFO, "$l10n_gui_ad_RecordTwoRoads;", 1000)
    end

    local startNodeId, _ = self.vehicle:getClosestWayPoint()
    local startNode = ADGraphManager:getWayPointById(startNodeId)

    if self.isSubPrio then
        self.flags = self.flags + AutoDrive.FLAG_SUBPRIO
    end

    local rearOffset = -2

    self.drivingReverse = (self.vehicle.lastSpeedReal * self.vehicle.movingDirection) < 0
    local firstNode, secondNode = self:getRecordingPoints()
    local x1, y1, z1 = getWorldTranslation(firstNode)
    if self.drivingReverse then
        -- no 2 road recording in reverse driving
        self.isRecordingTwoRoads = false
        x1, y1, z1 = AutoDrive.localToWorld(self.vehicle, 0, 0, rearOffset, self.vehicle.ad.specialDrivingModule:getReverseNode())
    end
    self.lastWp = ADGraphManager:recordWayPoint(x1, y1, z1, false, false, self.drivingReverse, 0, self.flags)
    if self.isRecordingTwoRoads and secondNode then
        local x2, y2, z2 = getWorldTranslation(secondNode)
        self.lastWp2 = ADGraphManager:recordWayPoint(x2, y2, z2, false, false, self.drivingReverse, 0, self.flags)
    end

    if not self.isRecordingTwoRoads and AutoDrive.getSetting("autoConnectStart") then
        -- no autoconnect for 2 road recording
        if startNode ~= nil then
            if ADGraphManager:getDistanceBetweenNodes(startNodeId, self.lastWp.id) < 12 then
                ADGraphManager:toggleConnectionBetween(startNode, self.lastWp, self.drivingReverse, self.isDual)
            end
        end
    end
    self.isRecording = true
    self.isRecordingReverse = self.drivingReverse
    self.wasRecordingTwoRoads = self.isRecordingTwoRoads
end

function ADRecordingModule:stop()
    if not (self.isRecordingTwoRoads or self.wasRecordingTwoRoads ~= self.isRecordingTwoRoads) and AutoDrive.getSetting("autoConnectEnd") then
        -- no autoconnect for 2 road recording or if changed between single and two road recording
        if self.lastWp ~= nil then
            local targetId = ADGraphManager:findMatchingWayPointForVehicle(self.vehicle)
            local targetNode = ADGraphManager:getWayPointById(targetId)
            if targetNode ~= nil then
                ADGraphManager:toggleConnectionBetween(self.lastWp, targetNode, false, self.isDual)
            end
        end
    end
    self:reset()
end

function ADRecordingModule:updateTick(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    if not AutoDrive.getSetting("RecordWhileNotInVehicle") then
        if not self.vehicle.ad.stateModule:isInCreationMode() then
            return
        end
    end
    if self.lastWp == nil or not self.isRecording then
        return
    end

    local firstNode, secondNode = self:getRecordingPoints()
    local diffX, diffY, diffZ = AutoDrive.worldToLocal(self.vehicle, self.lastWp.x, self.lastWp.y, self.lastWp.z, firstNode)
    self.drivingReverse = self.isRecordingReverse
    if self.isRecordingReverse and (diffZ < -1) then
        self.drivingReverse = false
    elseif not self.isRecordingReverse and (diffZ > 1) then
        self.drivingReverse = true
    end
    self.isRecordingTwoRoads = AutoDrive.getSetting("RecordTwoRoads") ~= 0
    if self.wasRecordingTwoRoads ~= self.isRecordingTwoRoads then
        -- disable recording if changed between single and two road recording
        self.vehicle.ad.stateModule:disableCreationMode()
        AutoDriveMessageEvent.sendNotification(self.vehicle, ADMessagesManager.messageTypes.ERROR, "$l10n_gui_ad_RecordTwoRoads;", 1000)
        return
    end
    if self.isRecordingTwoRoads then
        if self.drivingReverse then
            -- no 2 road recording in reverse driving - stop recording
            self.vehicle.ad.stateModule:disableCreationMode()
            AutoDriveMessageEvent.sendNotification(self.vehicle, ADMessagesManager.messageTypes.ERROR, "$l10n_gui_ad_RecordTwoRoads;", 1000)
            return
        else
            -- 2 road recording
            self:twoRoadRecording()
        end
    else
        -- 1 road recording
        self:singleRecording()
    end
    self.wasRecordingTwoRoads = self.isRecordingTwoRoads
end

function ADRecordingModule:singleRecording()
    local rearOffset = -2
    local vehicleX, _, vehicleZ = getWorldTranslation(self.vehicle.components[1].node)
    local reverseX, _, reverseZ = AutoDrive.localToWorld(self.vehicle, 0, 0, rearOffset, self.vehicle.ad.specialDrivingModule:getReverseNode())
    local x, y, z = getWorldTranslation(self:getRecordingPoints())

    if self.drivingReverse then
        x, y, z = AutoDrive.localToWorld(self.vehicle, 0, 0, rearOffset, self.vehicle.ad.specialDrivingModule:getReverseNode())
    end

    local minDistanceToLastWayPoint = true
    if self.isRecordingReverse ~= self.drivingReverse then
        --now we want a minimum distance from the last recording position to the last recorded point
        if self.isRecordingReverse then
            minDistanceToLastWayPoint = (MathUtil.vector2Length(reverseX - self.lastWp.x, reverseZ - self.lastWp.z) > 1)
        else
            if not self.isDual then
                minDistanceToLastWayPoint = (MathUtil.vector2Length(vehicleX - self.lastWp.x, vehicleZ - self.lastWp.z) > 1)
            else
                minDistanceToLastWayPoint = false
            end
        end
    end

    local speedMatchesRecording = (self.vehicle.lastSpeedReal * self.vehicle.movingDirection) > 0
    if self.drivingReverse then
        speedMatchesRecording = (self.vehicle.lastSpeedReal * self.vehicle.movingDirection) < 0
    end

    if self.secondLastWp == nil then
        if MathUtil.vector2Length(x - self.lastWp.x, z - self.lastWp.z) > 3 and MathUtil.vector2Length(vehicleX - self.lastWp.x, vehicleZ - self.lastWp.z) > 3 then
            self.secondLastWp = self.lastWp
            self.lastWp = ADGraphManager:recordWayPoint(x, y, z, true, self.isDual, self.drivingReverse, self.secondLastWp.id, self.flags)
            self.isRecordingReverse = self.drivingReverse
        end
    else
        local angle = math.abs(AutoDrive.angleBetween({x = x - self.secondLastWp.x, z = z - self.secondLastWp.z}, {x = self.lastWp.x - self.secondLastWp.x, z = self.lastWp.z - self.secondLastWp.z}))
        local max_distance = 6
        if angle < 0.5 then
            max_distance = 12
        elseif angle < 1 then
            max_distance = 6
        elseif angle < 2 then
            max_distance = 4
        elseif angle < 4 then
            max_distance = 3
        elseif angle < 7 then
            max_distance = 2
        elseif angle < 14 then
            max_distance = 1
        elseif angle < 27 then
            max_distance = 0.5
        else
            max_distance = 0.25
        end

        if self.drivingReverse then
            max_distance = math.min(max_distance, 2)
        end

        if MathUtil.vector2Length(x - self.lastWp.x, z - self.lastWp.z) > max_distance and minDistanceToLastWayPoint and speedMatchesRecording then
            self.secondLastWp = self.lastWp
            self.lastWp = ADGraphManager:recordWayPoint(x, y, z, true, self.isDual, self.drivingReverse, self.secondLastWp.id, self.flags)
            self.isRecordingReverse = self.drivingReverse
        end
    end
end

function ADRecordingModule:twoRoadRecording()
    local firstNode, secondNode = self:getRecordingPoints()

    self.speedMatchesRecording = (self.vehicle.lastSpeedReal * self.vehicle.movingDirection) > 0
    self.steeringAngle = math.deg(self.vehicle.rotatedTime)

    self.lastWp, self.secondLastWp = self:recordTwoRoad(firstNode, self.lastWp, self.secondLastWp, true)
    self.lastWp2, self.secondLastWp2 = self:recordTwoRoad(secondNode, self.lastWp2, self.secondLastWp2, false)
end

function ADRecordingModule:recordTwoRoad(node, lastWp, secondLastWp, right)
    local max_distance1 = 6
    local x1, y1, z1 = getWorldTranslation(node)
    local diffX, diffY, diffZ = AutoDrive.worldToLocal(self.vehicle, lastWp.x, lastWp.y, lastWp.z, node)
    if secondLastWp == nil then
        if math.abs(self.steeringAngle) > 10 then
            max_distance1 = 1
        else
            max_distance1 = 3
        end
        if MathUtil.vector2Length(x1 - lastWp.x, z1 - lastWp.z) > max_distance1 then
            secondLastWp = lastWp
            lastWp = ADGraphManager:recordWayPoint(x1, y1, z1, false, self.isDual, self.drivingReverse, secondLastWp.id, self.flags)
            if right then
                ADGraphManager:toggleConnectionBetween(secondLastWp, lastWp, self.drivingReverse, self.isDual)
            else
                ADGraphManager:toggleConnectionBetween(lastWp, secondLastWp, self.drivingReverse, self.isDual)
            end
        end
    else
        local angle1 = math.abs(AutoDrive.angleBetween({x = x1 - secondLastWp.x, z = z1 - secondLastWp.z}, {x = lastWp.x - secondLastWp.x, z = lastWp.z - secondLastWp.z}))
        if angle1 < 0.5 then
            max_distance1 = 12
        elseif angle1 < 1 then
            max_distance1 = 6
        elseif angle1 < 2 then
            max_distance1 = 4
        elseif angle1 < 4 then
            max_distance1 = 3
        elseif angle1 < 7 then
            max_distance1 = 2
        elseif angle1 < 14 then
            max_distance1 = 1
        elseif angle1 < 27 then
            max_distance1 = 0.5
        else
            max_distance1 = 0.25
        end
        if (self.steeringAngle < -15 and right)
            or (self.steeringAngle > 15 and not right) then
            -- steering right / left inner cicle for RHD / LHD
            max_distance1 = 1
        end
        if MathUtil.vector2Length(x1 - lastWp.x, z1 - lastWp.z) > max_distance1 and diffZ < -0.2 and self.speedMatchesRecording then
            secondLastWp = lastWp
            lastWp = ADGraphManager:recordWayPoint(x1, y1, z1, false, self.isDual, self.drivingReverse, secondLastWp.id, self.flags)
            if right then
                ADGraphManager:toggleConnectionBetween(secondLastWp, lastWp, self.drivingReverse, self.isDual)
            else
                ADGraphManager:toggleConnectionBetween(lastWp, secondLastWp, self.drivingReverse, self.isDual)
            end
        end
    end
    return lastWp, secondLastWp
end

function ADRecordingModule:update(dt)
end

function ADRecordingModule:getRecordingPoints()
    local firstNode = self.vehicle.components[1].node
    local secondNode = nil
    if self.drivingReverse then
        firstNode = self.vehicle.ad.specialDrivingModule:getReverseNode()
    elseif self.isRecordingTwoRoads and self.vehicle.ad.ADLeftNode then
        firstNode = self.vehicle.ad.ADRightNode
        secondNode = self.vehicle.ad.ADLeftNode
        setTranslation(self.vehicle.ad.ADRightNode, -AutoDrive.getSetting("RecordTwoRoads"), 0, 0)
        setTranslation(self.vehicle.ad.ADLeftNode, AutoDrive.getSetting("RecordTwoRoads"), 0, 0)
    end

    return firstNode, secondNode
end
