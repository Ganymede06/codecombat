CocoClass = require 'lib/CocoClass'

# If I were the kind of math major who remembered his math, this would all be done with matrix transforms.

r2d = (radians) -> radians * 180 / Math.PI
d2r = (degrees) -> degrees / 180 * Math.PI

MAX_ZOOM = 8
MIN_ZOOM = 0.1
DEFAULT_ZOOM = 2.0
DEFAULT_TARGET = {x:0, y:0}
DEFAULT_TIME = 1000

# You can't mutate any of the constructor parameters after construction.
# You can only call zoomTo to change the zoom target and zoom level.
module.exports = class Camera extends CocoClass
  @PPM: 10   # pixels per meter
  @MPP: 0.1  # meters per pixel; should match @PPM

  bounds: null # list of two surface points defining the viewable rectangle in the world
                # or null if there are no bounds

  # what the camera is pointed at right now
  target: DEFAULT_TARGET
  zoom: DEFAULT_ZOOM

  # properties for tracking going between targets
  oldZoom: null
  newZoom: null
  oldTarget: null
  newTarget: null
  tweenProgress: 0.0

  instant: false

  # INIT

  subscriptions:
    'camera-zoom-in': 'onZoomIn'
    'camera-zoom-out': 'onZoomOut'
    'surface:mouse-scrolled': 'onMouseScrolled'
    'level:restarted': 'onLevelRestarted'

  # TODO: Fix tests to not use mainLayer
  constructor: (@canvasWidth, @canvasHeight, angle=Math.asin(0.75), hFOV=d2r(30)) ->
    super()
    @calculateViewingAngle angle
    @calculateFieldOfView hFOV
    @calculateAxisConversionFactors()
    @updateViewports()
    @calculateMinZoom()

  calculateViewingAngle: (angle) ->
    # Operate on open interval between 0 - 90 degrees to make the math easier
    epsilon = 0.000001  # Too small and numerical instability will get us.
    @angle = Math.max(Math.min(Math.PI / 2 - epsilon, angle), epsilon)
    if @angle isnt angle and angle isnt 0 and angle isnt Math.PI / 2
      console.log "Restricted given camera angle of #{r2d(angle)} to #{r2d(@angle)}."

  calculateFieldOfView: (hFOV) ->
    # http://en.wikipedia.org/wiki/Field_of_view_in_video_games
    epsilon = 0.000001  # Too small and numerical instability will get us.
    @hFOV = Math.max(Math.min(Math.PI - epsilon, hFOV), epsilon)
    if @hFOV isnt hFOV and hFOV isnt 0 and hFOV isnt Math.PI
      console.log "Restricted given horizontal field of view to #{r2d(hFOV)} to #{r2d(@hFOV)}."
    @vFOV = 2 * Math.atan(Math.tan(@hFOV / 2) * @canvasHeight / @canvasWidth)
    if @vFOV > Math.PI
      console.log "Vertical field of view problem: expected canvas not to be taller than it is wide with high field of view."
      @vFOV = Math.PI - epsilon

  calculateAxisConversionFactors: ->
    @y2x = Math.sin @angle      # 1 unit along y is equivalent to y2x units along x
    @z2x = Math.cos @angle      # 1 unit along z is equivalent to z2x units along x
    @z2y = @z2x / @y2x          # 1 unit along z is equivalent to z2y units along y
    @x2y = 1 / @y2x             # 1 unit along x is equivalent to x2y units along y
    @x2z = 1 / @z2x             # 1 unit along x is equivalent to x2z units along z
    @y2z = 1 / @z2y             # 1 unit along y is equivalent to y2z units along z

  # CONVERSIONS AND CALCULATIONS

  worldToSurface: (pos) ->
    x = pos.x * Camera.PPM
    y = -pos.y * @y2x * Camera.PPM
    if pos.z
      y -= @z2y * @y2x * pos.z * Camera.PPM
    {x: x, y: y}

  surfaceToCanvas: (pos) ->
    {x: (pos.x - @surfaceViewport.x) * @zoom, y: (pos.y - @surfaceViewport.y) * @zoom}

  # TODO: do we even need separate screen coordinates?
  # We would need some other properties for the actual ratio of screen size to canvas size.
  canvasToScreen: (pos) ->
    #{x: pos.x * @someCanvasToScreenXScaleFactor, y: pos.y * @someCanvasToScreenYScaleFactor}
    {x: pos.x, y: pos.y}

  screenToCanvas: (pos) ->
    #{x: pos.x / @someCanvasToScreenXScaleFactor, y: pos.y / @someCanvasToScreenYScaleFactor}
    {x: pos.x, y: pos.y}

  canvasToSurface: (pos) ->
    {x: pos.x / @zoom + @surfaceViewport.x, y: pos.y / @zoom + @surfaceViewport.y}

  surfaceToWorld: (pos) ->
    {x: pos.x * Camera.MPP, y: -pos.y * Camera.MPP * @x2y, z: 0}

  canvasToWorld: (pos) -> @surfaceToWorld @canvasToSurface pos
  worldToCanvas: (pos) -> @surfaceToCanvas @worldToSurface pos
  worldToScreen: (pos) -> @canvasToScreen @worldToCanvas pos
  surfaceToScreen: (pos) -> @canvasToScreen @surfaceToCanvas pos
  screenToSurface: (pos) -> @canvasToSurface @screenToCanvas pos
  screenToWorld: (pos) -> @surfaceToWorld @screenToSurface pos

  cameraWorldPos: ->
    # I tried to figure out the math for how much of @vFOV is below the midpoint (botFOV) and how much is above (topFOV), but I failed.
    # So I'm just making something up. This would give botFOV 20deg, topFOV 10deg at @vFOV 30deg and @angle 45deg, or an even 15/15 at @angle 90deg.
    botFOV = @x2y * @vFOV / (@y2x + @x2y)
    topFOV = @y2x * @vFOV / (@y2x + @x2y)
    botDist = @worldViewport.height / 2 * Math.sin(@angle) / Math.sin(botFOV)
    z = botDist * Math.sin(@angle + botFOV)
    x: @worldViewport.cx, y: @worldViewport.cy - z * @z2y, z: z

  distanceTo: (pos) ->
    # Get the physical distance in meters from the camera to the given world pos.
    cpos = @cameraWorldPos()
    dx = pos.x - cpos.x
    dy = pos.y - cpos.y
    dz = (pos.z or 0) - cpos.z
    Math.sqrt dx * dx + dy * dy + dz * dz

  distanceRatioTo: (pos) ->
    # Get the ratio of the distance to the given world pos over the distance to the center of the camera view.
    cpos = @cameraWorldPos()
    dy = @worldViewport.cy - cpos.y
    camDist = Math.sqrt(dy * dy + cpos.z * cpos.z)
    return @distanceTo(pos) / camDist

    # Old method for flying things below; could re-integrate this
    ## Because none of our maps are designed to get smaller with distance along the y-axis, we'll only use z, as if we were looking straight down, until we get high enough. Based on worldPos.z, we gradually shift over to the more-realistic scale. This is pretty hacky.
    #ratioWithoutY = dz * dz / (cPos.z * cPos.z)
    #zv = Math.min(Math.max(0, worldPos.z - 5), cPos.z - 5) / (cPos.z - 5)
    #zv * ratioWithY + (1 - zv) * ratioWithoutY

  # SUBSCRIPTIONS

  onZoomIn: (e) -> @zoomTo @target, @zoom * 1.15, 300
  onZoomOut: (e) -> @zoomTo @target, @zoom / 1.15, 300
  onMouseScrolled: (e) ->
    ratio = 1 + 0.05 * Math.sqrt(Math.abs(e.deltaY))
    ratio = 1 / ratio if e.deltaY > 0
    @zoomTo @target, @zoom * ratio, 0
  onLevelRestarted: ->
    @setBounds(@firstBounds)

  # COMMANDS

  setBounds: (worldBounds) ->
    # receives an array of two world points. Normalize and apply them
    @firstBounds = worldBounds unless @firstBounds
    @bounds = @normalizeBounds(worldBounds)
    @calculateMinZoom()
    @updateZoom true
    @target = @currentTarget unless @target.name

  normalizeBounds: (worldBounds) ->
    return null unless worldBounds
    top = Math.max(worldBounds[0].y, worldBounds[1].y)
    left = Math.min(worldBounds[0].x, worldBounds[1].x)
    bottom = Math.min(worldBounds[0].y, worldBounds[1].y)
    right = Math.max(worldBounds[0].x, worldBounds[1].x)
    bottom -= 1 if top is bottom
    right += 1 if left is right
    p1 = @worldToSurface({x:left, y:top})
    p2 = @worldToSurface({x:right, y:bottom})
    {x:p1.x, y:p1.y, width:p2.x-p1.x, height:p2.y-p1.y}

  calculateMinZoom: ->
    # Zoom targets are always done in Surface coordinates.
    if not @bounds
      @minZoom = 0.5
      return
    @minZoom = Math.max @canvasWidth / @bounds.width, @canvasHeight / @bounds.height
    @zoom = Math.max(@minZoom, @zoom) if @zoom

  zoomTo: (newTarget=null, newZoom=1.0, time=1500) ->
    # Target is either just a {x, y} pos or a display object with {x, y} that might change; surface coordinates.
    time = 0 if @instant
    newTarget ?= {x:0, y:0}
    newTarget = (@newTarget or @target) if @locked 
    newZoom = Math.min((Math.max @minZoom, newZoom), MAX_ZOOM)
    return if @zoom is newZoom and newTarget is newTarget.x and newTarget.y is newTarget.y

    @finishTween(true)
    if time
      @newTarget = newTarget
      @oldTarget = @boundTarget(@target, @zoom)
      @oldZoom = @zoom
      @newZoom = newZoom
      @tweenProgress = 0.01
      createjs.Tween.get(@)
        .to({tweenProgress: 1.0}, time, createjs.Ease.getPowInOut(3))
        .call @onTweenEnd

    else
      @target = newTarget
      @zoom = newZoom
      @updateZoom true

  onTweenEnd: => @finishTween()

  finishTween: (abort=false) =>
    createjs.Tween.removeTweens(@)
    return unless @newTarget
    unless abort
      @target = @newTarget
      @zoom = @newZoom
    @newZoom = @oldZoom = @newTarget = @newTarget = @tweenProgress = null
    @updateZoom true

  updateZoom: (force=false) ->
    # Update when we're focusing on a Thang, tweening, or forcing it, unless we're locked
    return if (not force) and (@locked or (not @newTarget and not @target?.name))
    if @newTarget
      t = @tweenProgress
      @zoom = @oldZoom + t * (@newZoom - @oldZoom)
      [p1, p2] = [@oldTarget, @boundTarget(@newTarget, @newZoom)]
      target = @target = x: p1.x + t * (p2.x - p1.x), y: p1.y + t * (p2.y - p1.y)
    else
      target = @boundTarget @target, @zoom
      return if not force and _.isEqual target, @currentTarget
    @currentTarget = target
    @updateViewports target
    Backbone.Mediator.publish 'camera:zoom-updated', camera: @, zoom: @zoom, surfaceViewport: @surfaceViewport

  boundTarget: (pos, zoom) ->
    # Given an {x, y} in Surface coordinates, return one that will keep our viewport on the Surface.
    return pos unless @bounds
    marginX = (@canvasWidth / zoom / 2)
    marginY = (@canvasHeight / zoom / 2)
    x = Math.min(Math.max(marginX + @bounds.x, pos.x), @bounds.x + @bounds.width - marginX)
    y = Math.min(Math.max(marginY + @bounds.y, pos.y), @bounds.y + @bounds.height - marginY)
    {x: x, y: y}

  updateViewports: (target) ->
    target ?= @target
    sv = width: @canvasWidth / @zoom, height: @canvasHeight / @zoom, cx: target.x, cy: target.y
    sv.x = sv.cx - sv.width / 2
    sv.y = sv.cy - sv.height / 2
    @surfaceViewport = sv

    wv = @surfaceToWorld sv  # get x and y
    wv.width = sv.width * Camera.MPP
    wv.height = sv.height * Camera.MPP * @x2y
    wv.cx = wv.x + wv.width / 2
    wv.cy = wv.y + wv.height / 2
    @worldViewport = wv

  lock: ->
    @target = @currentTarget
    @locked = true
  unlock: ->
    @locked = false
