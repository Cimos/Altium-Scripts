{*******************************************************************************
  PolarChannelArray.pas  -- REVISED v16
  Altium DelphiScript -- Arrange channel "rooms" in a circular (polar) array.

  ================================================================
  WHAT CHANGED IN v16
  ================================================================
  Bug fix: restore the per-primitive ownership-routing layer that v14-1st
  (commit 613d526) introduced for exactly the symptom seen on MotionJigBase
  with 12 channels (bench observation 2026-05-15). v15.2 explicitly flagged
  this re-exposure: "Latent risk this fix re-exposes: bbox-overlap cross-
  claim on tight pre-script layouts where channel bbox+margin regions
  intersect... If the next board surfaces the starburst / fan-duplication
  symptom... restore ownership routing from 613d526 as v16." That board
  arrived; v16 restores it.

  User-observed symptom: "the second item in the array is bang on, but
  everything from then on has a rotation that it should not have."
  Diagnosis (cross-claim mechanism, confirmed by the symmetric pattern):

    - Channel i=1 (first non-reference) runs first. Its spatial query
      covers PreBBoxes[1] expanded by margin (5-50 mm via ComputeMargin).
      When channel-2's pre-script bbox+margin overlaps channel-1's, the
      iterator returns SOME of channel-2's tracks alongside channel-1's
      own. DoneSet marks them transformed at theta_1 = 360/N.
    - When channel i=2 runs, its spatial query finds only the tracks NOT
      already in DoneSet. Channel i=2 ends up with a MIX of theta_1-
      rotated tracks (stolen by i=1) and theta_2-rotated tracks (kept
      for itself). Visible result: channel i=1 looks perfect; channels
      i=2..N-1 have correctly-placed components but tracks at mixed
      rotations.

  Fix: re-add three helpers from v14-1st verbatim:
    1. PrimitiveCentroidXY  -- centroid math for any free primitive.
    2. IsPrimitiveOwnedBy   -- OwnerMap lookup gate.
    3. BuildPrimitiveOwnership -- one-time pre-pass assigning each free
       primitive to its NEAREST pre-script channel centre (Euclidean
       distance in mm to avoid TCoord^2 overflow), validated against
       that channel's bbox+margin. Stores 'PrimitiveKey=chanIdx' per
       primitive in OwnerMap. Primitives outside any channel's bbox+
       margin have no owner and are left alone by the polar loop.

  TransformChannelFreePrimitives now takes (OwnerMap, chanIdx) and gates
  every case branch on IsPrimitiveOwnedBy(key, chanIdx) before adding to
  DoneSet. The bbox/margin filter stays as a cheap pre-check; OwnerMap is
  the precise filter. OwnerMap is built BEFORE the reset step (same as
  v14-1st) -- it has to see pre-script positions because that's when
  tracks align with their owning channel's pre-script bbox.

  Geometric formula in TransformChannelFreePrimitives is unchanged:
    P_final = newC + R_theta(P - preC)
  Math was verified correct in v15 by independent critique (the worked
  example for N=14, refC=(0,-100), polarO=(0,0), channel B at (-50,-100)
  with track at (-50,-80) yields v15 prediction matching the correct
  rigid-body destination to within 0.01 mm). v16 changes nothing about
  the math, only the attribution of "which channel owns which primitive."

  Known limitations of nearest-centre ownership (carried over from v14-1st):
    - If a channel's primitives happen to sit closer to a NEIGHBOUR's
      pre-script centre than to their own, ownership goes to the
      neighbour. The PointInRect-against-neighbour-bbox+margin
      validation may pass (-> primitive moves with the neighbour, wrong
      visually) or fail (-> primitive has no owner and stays put,
      orphan). For layouts where channels are radially symmetric around
      a central feeder this is rare; for arbitrary user-placed pre-
      script layouts it can happen. Manifests as a small number of
      stragglers, not a wholesale rotation error.

  ================================================================
  WHAT CHANGED IN v15.2
  ================================================================
  Bug fix: restore the 25 % bbox-margin extension in the per-primitive
  PointInRect filter inside TransformChannelFreePrimitives. v15 left the
  margin on the spatial iterator (AddFilter_Area at lines ~476-477) but
  silently stripped it from the six PointInRect checks inside the loop.
  Result: the iterator surfaced free primitives sitting in the margin
  band (just outside the components' raw bounding box), the PointInRect
  centroid test then rejected them, and they were left at their pre-
  rotation position. Visible symptom: "all the track work is still off"
  -- components rotate correctly, but routing tracks adjacent to but
  outside the raw component cluster stay behind.

  The fix is one-line per primitive type (track / via / arc / fill /
  text / pad): change PointInRect(..., bx1, by1, bx2, by2) to
  PointInRect(..., bx1 - margin, by1 - margin, bx2 + margin, by2 + margin).
  This matches the spatial iterator's AddFilter_Area on the same call --
  iterator and centroid filter are now consistent. The 25 % margin
  promised by README sections "Automatic reset" and "Stragglers left
  behind" is restored.

  Latent risk this fix re-exposes: bbox-overlap cross-claim on tight pre-
  script layouts where channel bbox+margin regions intersect. v14-1st
  hedged this with BuildPrimitiveOwnership / OwnerMap (commit 613d526),
  v14-final + v15 dropped it on the grounds that "channel bboxes don't
  overlap" -- which is true for raw bboxes but NOT for bbox+margin. If
  the next board surfaces the starburst / fan-duplication symptom (free
  primitives showing up on more than one rotated channel), restore
  ownership routing from 613d526 as v16. The geometric fix (newCX/newCY
  destination, rotation pivot at preC) is untouched.

  ================================================================
  WHAT CHANGED FROM v14
  ================================================================
  Bug fix: restore the empirical channel-suffix derivation that v14-final
  (1214a87) silently dropped when it stripped the ownership-routing
  layer from v14-1st (613d526). On a board where component designators
  do NOT end with '_' + className -- e.g. class "U_DUTB" but components
  "M4_U_DUT1", "R3_U_DUT2" (MotionJigBase 2026-05-14) -- v14-final's
  StripChannelSuffix returns the full designator, FindMatchingComponent
  finds no match, ResetChannelsToMatchReference returns 0 matches, every
  non-reference channel's components stay at their pre-script positions,
  and the polar transform rotates them around refC anyway. Each channel
  lands at a different radius from polarO and the result is the
  "elliptical orbit growing as it goes around" pattern -- the SAME
  symptom v14-1st had originally fixed.

  Fix:
    1. Re-add SnapSuffixToUnderscore (longest tail starting with '_').
    2. Re-add DeriveClassSuffix (longest common trailing substring of
       component designators in the class, snapped to start with '_').
    3. StripChannelSuffix and FindMatchingComponent now take a PRE-
       DERIVED suffix rather than reconstructing it from the class name.
    4. ResetChannelsToMatchReference computes the suffix for every
       channel once at the top, stores them in a parallel TStringList,
       and feeds the per-channel suffix into StripChannelSuffix.

  Empty derived suffix is a valid result -- means the channel has only
  one component (no trailing substring to align against) or has no
  detectable common tail. StripChannelSuffix in that case is a no-op
  (root = full designator). Works for the previous-known case
  (class==suffix, e.g. class "U_DUTB" with designators "C1_U_DUTB")
  AND the newly-found case (class!=suffix, e.g. class "U_DUTB" with
  designator "M4_U_DUT1").

  The geometric fix is untouched (newCX/newCY destination for free
  primitives, rotation pivot at preC). That part was correct in both
  v14-1st and v14-final; only the suffix-derivation regression
  produced the user-visible spiral on MotionJigBase.

  What v14-1st had that v15 does NOT bring back:
    - BuildPrimitiveOwnership / OwnerMap / IsPrimitiveOwnedBy. This
      was a hedge against bbox-overlap cross-claim on tight channel
      layouts (multiple channels' bbox+margin regions intersecting,
      primitives grabbed by whichever iteration ran first, "starburst"
      symptom). v14-final dropped it on the grounds that the simple
      "PointInRect inside raw bbox + DoneSet dedup" filter is
      sufficient when channel bboxes don't overlap. If a future board
      surfaces the starburst symptom, re-add ownership routing as v16
      (lives in git history at 613d526).
    - Per-channel diagnostic counters from v14.1 (f1f2fea).

  Worked example (N=3, MotionJigBase-style naming):
    Classes [U_DUTB, U_DUTC, U_DUTD], designators in U_DUTB end with
    "_U_DUT1", in U_DUTC end with "_U_DUT2", in U_DUTD end with
    "_U_DUT3". User clicks a component in U_DUTB (reference).

    v14-final: StripChannelSuffix("M4_U_DUT2", "U_DUTC") looks for
      suffix "_U_DUTC" at the end of "M4_U_DUT2" -- not found, returns
      "M4_U_DUT2" unchanged. FindMatchingComponent in U_DUTB looks for
      a component whose stripped root is "M4_U_DUT2" -- not found
      (U_DUTB components strip to "M4", "R3", etc.). resetMatched=0,
      U_DUTC components stay at preC, polar transform rotates them
      around refC, U_DUTC cluster lands at refC + R(120)*(preC - refC)
      which is NOT on the polar circle. Spiral pattern.

    v15: DeriveClassSuffix(U_DUTC) walks every component in U_DUTC,
      finds the longest common trailing substring "_U_DUT2", returns
      "_U_DUT2" (after snap-to-underscore). StripChannelSuffix(
      "M4_U_DUT2", "_U_DUT2") strips to "M4". FindMatchingComponent
      in U_DUTB with refSuffix="_U_DUT1" finds component "M4_U_DUT1"
      (strips to "M4"). MATCH. U_DUTC components reset to refC.
      Polar transform lands them at newC on the polar circle.

  ================================================================
  WHAT CHANGED FROM v13 (v14 summary)
  ================================================================
  v14 made two changes that got entangled:
    1. (v14-1st, 613d526) Empirical-suffix derivation so reset works
       on boards where Altium decoupled class name from designator
       suffix. Silently reverted in v14-final; restored in v15.
    2. (v14-1st through v14-final) Free-primitive destination: tracks
       were landing at rotate(preC, polarO) -- a different ring from
       components -- instead of newC = rotate(refC, polarO) alongside
       components. One-liner at the call site (newCX/newCY instead of
       newPreCX/newPreCY). Preserved in v15.

       Components end at  newC = rotate(refC, polarO, theta).
       Tracks end at      newC + R_theta(P - preC)
                          -- preserves the track-to-component relative
                          offset under rotation.

  ================================================================
  WHAT CHANGED FROM v12 (v13 summary)
  ================================================================
  Bug fix (partial): free tracks / vias / arcs / fills / text / free
  pads belonging to non-reference channels were ending up at random
  positions after the polar array ran. v13 fixed the spatial-query
  half of this bug. See v14 above for the destination half.

  Root cause: TransformChannelFreePrimitives was being called with
  the POST-reset bounding box -- which, for every non-reference
  channel, is identical to the reference channel's bounding box
  (because the reset step copies non-reference components to the
  reference position). The spatial iterator therefore looked for
  channel C's free primitives at the REFERENCE location, found
  none (the free primitives weren't moved by reset), and instead
  picked up the REFERENCE channel's free primitives. Because the
  DoneSet dedupes, the reference channel's tracks got rotated to
  the first non-reference channel's destination on the first
  iteration, never moved again, and every subsequent channel
  found no primitives in its query area at all.

  v13 fix: snapshot each channel's bounding box BEFORE the reset
  step runs. In the polar step, free-primitive transforms use the
  channel's pre-reset bounding box for the spatial query region.
  Components still use the post-reset (= reference) bounding box,
  because that's where they are when the polar step runs.

  New helpers: SnapshotChannelBBoxes, GetBBoxFromSnapshot.

  ================================================================
  WHAT CHANGED FROM v11 (v12 summary)
  ================================================================
  Bug fix: clicking a component inside the board outline used to fail
  with the error "Could not derive a channel prefix from 'Inside Board
  Components'". The cause was FindChannelClassForComponent picking the
  longest-named class the component was in -- but a component on a
  board sits in (at least) THREE classes simultaneously: the user's
  channel class (e.g. "U_DUTB", 6 chars), "All Components" (14 chars),
  and "Inside Board Components" (23 chars). The longest-name heuristic
  picked the wrong one because Altium's auto-classes have long names.

  Fix: filter out Altium auto-maintained component classes before any
  membership search. New helper IsBuiltInComponentClass (line ~125)
  uses Cls.SuperClass first, with a name blacklist fallback for older
  Altium builds. Applied at FindChannelClassForComponent,
  CollectMatchingClasses, and DerivePrefixFromReference.

  Also: if the user has a component selected before running, that is
  used as the reference instead of prompting for a click. Pre-selection
  saves a step when the user already knows which component to use.

  ================================================================
  WHAT CHANGED FROM v10 (v11 summary)
  ================================================================
  Reference channel is now selected by CLICKING any component in the
  reference channel on the PCB, instead of typing a class-name prefix.
  The script resolves the click to the nearest component, reads its
  channel-specific component class membership to get the reference
  class name, and auto-derives the channel-set prefix by finding the
  longest name-prefix the clicked class shares with at least one other
  class on the board.

  (Rooms aren't used for selection because Altium's DelphiScript enum
   does not expose a standard room-object filter constant across all
   versions; components are iterated via the stable eComponentObject
   enum and carry the component-class membership we need.)

  ================================================================
  WHAT CHANGED FROM v9 (v10 summary)
  ================================================================
  Reset step is now AUTOMATIC (no longer optional). Before arranging,
  all non-reference channels are always normalised to match the
  reference channel's (e.g. U_DUTB) internal layout. This guarantees a
  clean starting state on every run, whether it is the first run or a
  repeat run on an already-arranged board.

  ================================================================
  WHAT CHANGED FROM v8 (v9 summary)
  ================================================================
  Added the reset step that normalises all non-reference channels to
  match the reference channel's internal layout BEFORE running the
  polar array.

  Why this matters: running the script a second time on an already-
  arranged board stacks another rotation on top of the existing one,
  because each component's rotation is added to. Same if the channels
  start out with inconsistent orientations -- the final ring will look
  uneven.

  The reset works by matching components across channels by their
  "root" designator (designator with the channel class suffix stripped),
  then copying the reference component's relative position and absolute
  rotation to each matching component in the other channels. After the
  reset, every channel is a positional copy of the reference -- ready
  for the polar array step.

  Note: free tracks/vias/fills belonging to non-reference channels are
  not moved by the reset step. They are handled in the polar arrangement
  step, but only if they sit within the reference channel's bounding box.

  ================================================================
  NOTE ON DIALOG POSITIONING
  ================================================================
  InputBox and MessageDlg dialogs may appear on a different monitor
  than Altium's main window. This is an OS-level active-window issue
  that DelphiScript cannot override from InputBox. Workarounds:
    - Click on the Altium PCB window before running the script.
    - For the interactive origin pick, Altium's crosshair mode always
      tracks the PCB window, so that part isn't affected.
*******************************************************************************}

const
  DEG_TO_RAD             = 0.017453292519943;
  MAX_CHANNELS_SAFETY    = 256;
  COMP_CLASS_MEMBER_KIND = 1;
  MARGIN_FRACTION        = 0.25;
  MARGIN_MIN_MM          = 5.0;
  MARGIN_MAX_MM          = 50.0;

{ --------------------------------------------------------------------------- }
procedure RotatePointXY(ix, iy        : TCoord;
                        cx, cy        : TCoord;
                        angleDeg      : Double;
                        var ox, oy    : TCoord);
var
  rad, cosA, sinA, dx, dy : Double;
begin
  rad  := angleDeg * DEG_TO_RAD;
  cosA := Cos(rad);
  sinA := Sin(rad);
  dx   := CoordToMMs(ix - cx);
  dy   := CoordToMMs(iy - cy);
  ox   := cx + MMsToCoord(dx * cosA - dy * sinA);
  oy   := cy + MMsToCoord(dx * sinA + dy * cosA);
end;

{ --------------------------------------------------------------------------- }
function NormaliseAngle(a : Double) : Double;
begin
  Result := a;
  while Result < 0      do Result := Result + 360.0;
  while Result >= 360.0 do Result := Result - 360.0;
end;

{ --------------------------------------------------------------------------- }
function PointInRect(x, y, x1, y1, x2, y2 : TCoord) : Boolean;
begin
  Result := (x >= x1) and (x <= x2) and (y >= y1) and (y <= y2);
end;

{ --------------------------------------------------------------------------- }
function PrimitiveKey(Prim : IPCB_Primitive) : String;
begin
  Result := '?';
  case Prim.ObjectId of
    eTrackObject:
      Result := 'T:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.X1) + ',' + IntToStr(Prim.Y1) + ',' +
                IntToStr(Prim.X2) + ',' + IntToStr(Prim.Y2);
    eViaObject:
      Result := 'V:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.X) + ',' + IntToStr(Prim.Y);
    eArcObject:
      { 2026-05-23: Radius + StartAngle + EndAngle added to key. Previously
        the key was Layer + XCenter + YCenter only -- concentric arcs (a
        common shape in fanout / impedance-controlled / differential
        routing, where many tracks share a turn centerpoint) hashed to the
        same key. The apply phase's DoneSet then accepted the first arc
        encountered and SILENTLY SKIPPED the rest, leaving 30%+ of free
        arcs as orphans. Worked example on MotionJigBase 2026-05-23:
        1,944 collision groups, 4,417 predicted orphans, observed on
        Simon's bench. Adding radius + angles makes every distinct arc
        unique. FloatToStrF on a stable Double is deterministic within
        one apply iteration -- the key is recomputed from the arc's
        in-memory state at each lookup, so as long as the arc has not
        been mutated between OwnerMap build and DoneSet lookup (it has
        not), the strings match. }
      Result := 'A:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.XCenter) + ',' + IntToStr(Prim.YCenter) + ',' +
                IntToStr(Prim.Radius) + ',' +
                FloatToStrF(Prim.StartAngle, ffFixed, 10, 4) + ',' +
                FloatToStrF(Prim.EndAngle,   ffFixed, 10, 4);
    eFillObject:
      Result := 'F:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.X1Location) + ',' + IntToStr(Prim.Y1Location) + ',' +
                IntToStr(Prim.X2Location) + ',' + IntToStr(Prim.Y2Location);
    eTextObject:
      Result := 'X:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.XLocation) + ',' + IntToStr(Prim.YLocation);
    ePadObject:
      Result := 'P:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.X) + ',' + IntToStr(Prim.Y);
    ePolyObject:
      { 2026-05-23: polygon key. Layer + bbox center + bbox dimensions.
        See [[feedback-altium-polygon-api-ad26]] -- Poly.PointCount
        accessible but adding it here for extra collision resistance
        per the arc-key lesson at [[project-polar-array-arc-orphan-root-cause]]. }
      Result := 'PG:' + IntToStr(Prim.Layer) + ',' +
                IntToStr((Prim.BoundingRectangle.Left + Prim.BoundingRectangle.Right) div 2) + ',' +
                IntToStr((Prim.BoundingRectangle.Bottom + Prim.BoundingRectangle.Top) div 2) + ',' +
                IntToStr(Prim.BoundingRectangle.Right - Prim.BoundingRectangle.Left) + ',' +
                IntToStr(Prim.BoundingRectangle.Top - Prim.BoundingRectangle.Bottom);
  end;
end;

{ ---------------------------------------------------------------------------
  IsBuiltInComponentClass
  Altium auto-creates 5 "system" component classes on every board:
  "All Components", "Inside Board Components", "Outside Board Components",
  "Top Side Components", "Bottom Side Components". Every component is a
  member of at least three of them (All + one of Inside/Outside + one of
  Top/Bottom), so a click-to-pick reference component returns several
  classes when we test IsMember, and several auto-class names are longer
  than the user channel class (e.g. "Inside Board Components" is 23 chars
  vs "U_DUTB" at 6). Always exclude them from class searches.

  IPCB_ObjectClass.SuperClass is True for auto-maintained classes (verified
  on AD25), but for older Altium builds we wrap it in try/except and fall
  through to a name blacklist if the property call raises a runtime error.
--------------------------------------------------------------------------- }
function IsBuiltInComponentClass(Cls : IPCB_ObjectClass) : Boolean;
var
  nm : String;
  isSuper : Boolean;
begin
  isSuper := False;
  try
    isSuper := Cls.SuperClass;
  except
    isSuper := False;
  end;
  if isSuper then
  begin
    Result := True;
    Exit;
  end;

  nm := Cls.Name;
  Result := (CompareText(nm, 'All Components') = 0) or
            (CompareText(nm, 'Inside Board Components') = 0) or
            (CompareText(nm, 'Outside Board Components') = 0) or
            (CompareText(nm, 'Top Side Components') = 0) or
            (CompareText(nm, 'Bottom Side Components') = 0);
end;

{ --------------------------------------------------------------------------- }
function FindClassByName(Board : IPCB_Board; name : String) : IPCB_ObjectClass;
var
  Iter : IPCB_BoardIterator;
  Prim : IPCB_Primitive;
  Cls  : IPCB_ObjectClass;
begin
  Result := Nil;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND) and (Cls.Name = name) then
    begin
      Result := Cls;
      Break;
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ ---------------------------------------------------------------------------
  CountClassMembers
  Returns the number of components belonging to the given class.
--------------------------------------------------------------------------- }
function CountClassMembers(Board : IPCB_Board; Cls : IPCB_ObjectClass) : Integer;
var
  Iter : IPCB_BoardIterator;
  Comp : IPCB_Component;
begin
  Result := 0;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);
  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if Cls.IsMember(Comp) then
      Result := Result + 1;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ --------------------------------------------------------------------------- }
procedure ComputeChannelBBox(Board : IPCB_Board;
                             Cls   : IPCB_ObjectClass;
                             var minX, minY, maxX, maxY : TCoord;
                             var count : Integer);
var
  Iter : IPCB_BoardIterator;
  Comp : IPCB_Component;
  L, B, R, T : TCoord;
begin
  count := 0;
  minX := 0; minY := 0; maxX := 0; maxY := 0;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if Cls.IsMember(Comp) then
    begin
      { Access BoundingRectangle fields directly. Each field read is a
        separate property call, which is slightly wasteful for large
        boards but avoids any TCoordRect local-variable concerns. }
      L := Comp.BoundingRectangle.Left;
      B := Comp.BoundingRectangle.Bottom;
      R := Comp.BoundingRectangle.Right;
      T := Comp.BoundingRectangle.Top;

      if count = 0 then
      begin
        minX := L; minY := B; maxX := R; maxY := T;
      end
      else
      begin
        if L < minX then minX := L;
        if B < minY then minY := B;
        if R > maxX then maxX := R;
        if T > maxY then maxY := T;
      end;
      count := count + 1;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ --------------------------------------------------------------------------- }
procedure TransformChannelComponents(Board    : IPCB_Board;
                                     Cls      : IPCB_ObjectClass;
                                     oldCX, oldCY : TCoord;
                                     newCX, newCY : TCoord;
                                     rotateDeg    : Double);
var
  Iter : IPCB_BoardIterator;
  Comp : IPCB_Component;
  dX, dY, tx, ty : TCoord;
begin
  dX := newCX - oldCX;
  dY := newCY - oldCY;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if Cls.IsMember(Comp) then
    begin
      RotatePointXY(Comp.X, Comp.Y, oldCX, oldCY, rotateDeg, tx, ty);
      Comp.X := tx + dX;
      Comp.Y := ty + dY;
      Comp.Rotation := NormaliseAngle(Comp.Rotation + rotateDeg);
      Comp.GraphicallyInvalidate;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ ---------------------------------------------------------------------------
  PrimitiveCentroidXY
  Returns the (cx, cy) for a free primitive, or (0,0)+result=False if the
  primitive's object kind isn't one we transform. Mirrors the centroid math
  used inside TransformChannelFreePrimitives so the two stay in lockstep.
  v16: restored from v14-1st (613d526) alongside the ownership-routing
  layer; used by BuildPrimitiveOwnership to test which channel owns each
  free primitive.
--------------------------------------------------------------------------- }
function PrimitiveCentroidXY(Prim : IPCB_Primitive;
                             var cx, cy : TCoord) : Boolean;
var
  track : IPCB_Track;
  via   : IPCB_Via;
  arc   : IPCB_Arc;
  txt   : IPCB_Text;
  pad   : IPCB_Pad;
begin
  Result := True;
  case Prim.ObjectId of
    eTrackObject:
    begin
      track := Prim;
      cx := (track.X1 + track.X2) div 2;
      cy := (track.Y1 + track.Y2) div 2;
    end;
    eViaObject:
    begin
      via := Prim;
      cx := via.X;
      cy := via.Y;
    end;
    eArcObject:
    begin
      arc := Prim;
      cx := arc.XCenter;
      cy := arc.YCenter;
    end;
    eFillObject:
    begin
      cx := (Prim.X1Location + Prim.X2Location) div 2;
      cy := (Prim.Y1Location + Prim.Y2Location) div 2;
    end;
    eTextObject:
    begin
      txt := Prim;
      cx := txt.XLocation;
      cy := txt.YLocation;
    end;
    ePadObject:
    begin
      pad := Prim;
      cx := pad.X;
      cy := pad.Y;
    end;
    ePolyObject:
    begin
      { 2026-05-23: polygon centroid = bbox center. Verified accessor
        per [[feedback-altium-polygon-api-ad26]]. }
      cx := (Prim.BoundingRectangle.Left + Prim.BoundingRectangle.Right) div 2;
      cy := (Prim.BoundingRectangle.Bottom + Prim.BoundingRectangle.Top) div 2;
    end;
  else
    begin
      cx := 0;
      cy := 0;
      Result := False;
    end;
  end;
end;

{ ---------------------------------------------------------------------------
  IsPrimitiveOwnedBy
  Returns True iff OwnerMap contains the exact entry 'key=chanIdx'.
  Uses TStringList.IndexOf full-string match, which is binary-search when
  OwnerMap.Sorted is True (same Sorted+IndexOf pattern as DoneSet below).

  Implementation note: original draft used IndexOfName / ValueFromIndex
  for cleaner code, but those are not in the verified TStringList API
  surface for this Altium build. Full-string match is sufficient because
  the caller already knows which chanIdx to ask about.
--------------------------------------------------------------------------- }
function IsPrimitiveOwnedBy(OwnerMap : TStringList;
                            key      : String;
                            chanIdx  : Integer) : Boolean;
begin
  Result := (OwnerMap.IndexOf(key + '=' + IntToStr(chanIdx)) >= 0);
end;

{ --------------------------------------------------------------------------- }
procedure TransformChannelFreePrimitives(Board    : IPCB_Board;
                                         DoneSet  : TStringList;
                                         OwnerMap : TStringList;
                                         chanIdx  : Integer;
                                         bx1, by1, bx2, by2 : TCoord;
                                         margin  : TCoord;
                                         oldCX, oldCY : TCoord;
                                         newCX, newCY : TCoord;
                                         rotateDeg    : Double);
var
  Iter : IPCB_SpatialIterator;
  PolyIter : IPCB_BoardIterator;
  Prim : IPCB_Primitive;
  dX, dY : TCoord;
  tx, ty, tx2, ty2 : TCoord;
  fillCX, fillCY, fillHW, fillHH : TCoord;
  key  : String;

  track : IPCB_Track;
  via   : IPCB_Via;
  arc   : IPCB_Arc;
  txt   : IPCB_Text;
  pad   : IPCB_Pad;
  poly  : IPCB_Polygon;
  seg   : TPolySegment;
  polyBBCX, polyBBCY : TCoord;
  pointCount, polyIdx : Integer;
  PolyLog : TStringList;
begin
  dX := newCX - oldCX;
  dY := newCY - oldCY;

  Iter := Board.SpatialIterator_Create;
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Area(bx1 - margin, by1 - margin,
                      bx2 + margin, by2 + margin);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    case Prim.ObjectId of

      eTrackObject:
      begin
        track := Prim;
        if (track.Component = Nil) and
           PointInRect((track.X1 + track.X2) div 2,
                       (track.Y1 + track.Y2) div 2,
                       bx1 - margin, by1 - margin,
                       bx2 + margin, by2 + margin) then
        begin
          key := PrimitiveKey(track);
          if (DoneSet.IndexOf(key) < 0) and
             IsPrimitiveOwnedBy(OwnerMap, key, chanIdx) then
          begin
            DoneSet.Add(key);
            RotatePointXY(track.X1, track.Y1, oldCX, oldCY, rotateDeg, tx,  ty);
            RotatePointXY(track.X2, track.Y2, oldCX, oldCY, rotateDeg, tx2, ty2);
            track.X1 := tx  + dX;  track.Y1 := ty  + dY;
            track.X2 := tx2 + dX;  track.Y2 := ty2 + dY;
            track.GraphicallyInvalidate;
          end;
        end;
      end;

      eViaObject:
      begin
        via := Prim;
        if (via.Component = Nil) and
           PointInRect(via.X, via.Y,
                       bx1 - margin, by1 - margin,
                       bx2 + margin, by2 + margin) then
        begin
          key := PrimitiveKey(via);
          if (DoneSet.IndexOf(key) < 0) and
             IsPrimitiveOwnedBy(OwnerMap, key, chanIdx) then
          begin
            DoneSet.Add(key);
            RotatePointXY(via.X, via.Y, oldCX, oldCY, rotateDeg, tx, ty);
            via.X := tx + dX;
            via.Y := ty + dY;
            via.GraphicallyInvalidate;
          end;
        end;
      end;

      eArcObject:
      begin
        arc := Prim;
        if (arc.Component = Nil) and
           PointInRect(arc.XCenter, arc.YCenter,
                       bx1 - margin, by1 - margin,
                       bx2 + margin, by2 + margin) then
        begin
          key := PrimitiveKey(arc);
          if (DoneSet.IndexOf(key) < 0) and
             IsPrimitiveOwnedBy(OwnerMap, key, chanIdx) then
          begin
            DoneSet.Add(key);
            RotatePointXY(arc.XCenter, arc.YCenter, oldCX, oldCY, rotateDeg, tx, ty);
            arc.XCenter    := tx + dX;
            arc.YCenter    := ty + dY;
            arc.StartAngle := NormaliseAngle(arc.StartAngle + rotateDeg);
            arc.EndAngle   := NormaliseAngle(arc.EndAngle   + rotateDeg);
            arc.GraphicallyInvalidate;
          end;
        end;
      end;

      eFillObject:
      begin
        if Prim.Component = Nil then
        begin
          fillCX := (Prim.X1Location + Prim.X2Location) div 2;
          fillCY := (Prim.Y1Location + Prim.Y2Location) div 2;
          fillHW := (Prim.X2Location - Prim.X1Location) div 2;
          fillHH := (Prim.Y2Location - Prim.Y1Location) div 2;

          if PointInRect(fillCX, fillCY,
                         bx1 - margin, by1 - margin,
                         bx2 + margin, by2 + margin) then
          begin
            key := PrimitiveKey(Prim);
            if (DoneSet.IndexOf(key) < 0) and
             IsPrimitiveOwnedBy(OwnerMap, key, chanIdx) then
            begin
              DoneSet.Add(key);
              RotatePointXY(fillCX, fillCY, oldCX, oldCY, rotateDeg, tx, ty);
              Prim.X1Location := (tx + dX) - fillHW;
              Prim.Y1Location := (ty + dY) - fillHH;
              Prim.X2Location := (tx + dX) + fillHW;
              Prim.Y2Location := (ty + dY) + fillHH;
              Prim.Rotation := NormaliseAngle(Prim.Rotation + rotateDeg);
              Prim.GraphicallyInvalidate;
            end;
          end;
        end;
      end;

      eTextObject:
      begin
        txt := Prim;
        if (txt.Component = Nil) and
           PointInRect(txt.XLocation, txt.YLocation,
                       bx1 - margin, by1 - margin,
                       bx2 + margin, by2 + margin) then
        begin
          key := PrimitiveKey(txt);
          if (DoneSet.IndexOf(key) < 0) and
             IsPrimitiveOwnedBy(OwnerMap, key, chanIdx) then
          begin
            DoneSet.Add(key);
            RotatePointXY(txt.XLocation, txt.YLocation, oldCX, oldCY,
                          rotateDeg, tx, ty);
            txt.XLocation := tx + dX;
            txt.YLocation := ty + dY;
            txt.Rotation  := NormaliseAngle(txt.Rotation + rotateDeg);
            txt.GraphicallyInvalidate;
          end;
        end;
      end;

      ePadObject:
      begin
        pad := Prim;
        if (pad.Component = Nil) and
           PointInRect(pad.X, pad.Y,
                       bx1 - margin, by1 - margin,
                       bx2 + margin, by2 + margin) then
        begin
          key := PrimitiveKey(pad);
          if (DoneSet.IndexOf(key) < 0) and
             IsPrimitiveOwnedBy(OwnerMap, key, chanIdx) then
          begin
            DoneSet.Add(key);
            RotatePointXY(pad.X, pad.Y, oldCX, oldCY, rotateDeg, tx, ty);
            pad.X := tx + dX;
            pad.Y := ty + dY;
            pad.Rotation := NormaliseAngle(pad.Rotation + rotateDeg);
            pad.GraphicallyInvalidate;
          end;
        end;
      end;

    end; { case }

    Prim := Iter.NextPCBObject;
  end; { while }

  Board.SpatialIterator_Destroy(Iter);

  { ---- Polygon pass (added 2026-05-23) ----
    Bench-observed 2026-05-23: putting ePolyObject in the SpatialIterator
    case statement did NOT move polygons. Suspect SpatialIterator's
    bbox-based query does not enumerate polygons reliably (probably
    treats them as their fill primitives rather than the outline
    object). Switch to BoardIterator with explicit ObjectSet -- same
    pattern that BuildPrimitiveOwnership uses (and that pass DOES
    return polygons cleanly, verified by probe-1).

    DoneSet still protects against any double-move (if Altium ever
    returned a polygon from BOTH iterators, the second visit skips). }
  { Per-call diagnostic log (instrument added 2026-05-23 because the
    polygon-mover produced visually-wrong results despite the math
    checking out on paper). Appends to a board-wide log file so the
    next bench run shows EVERY polygon-move attempt: pre-bbox,
    chanIdx, rotateDeg, pivot, dX/dY, ownership-attribution result,
    post-bbox. Remove after diagnosing. }
  PolyLog := TStringList.Create;
  if chanIdx > 1 then
  begin
    try
      PolyLog.LoadFromFile('C:\Users\Public\polygon-move.log');
    except
    end;
  end;
  PolyLog.Add('--- chanIdx=' + IntToStr(chanIdx) +
              '  rotateDeg=' + FloatToStrF(rotateDeg, ffFixed, 10, 3) +
              '  oldC=(' + FloatToStrF(CoordToMMs(oldCX), ffFixed, 10, 3) +
              ',' + FloatToStrF(CoordToMMs(oldCY), ffFixed, 10, 3) + ')' +
              '  newC=(' + FloatToStrF(CoordToMMs(newCX), ffFixed, 10, 3) +
              ',' + FloatToStrF(CoordToMMs(newCY), ffFixed, 10, 3) + ')' +
              '  dXY=(' + FloatToStrF(CoordToMMs(dX), ffFixed, 10, 3) +
              ',' + FloatToStrF(CoordToMMs(dY), ffFixed, 10, 3) + ')');

  PolyIter := Board.BoardIterator_Create;
  PolyIter.AddFilter_ObjectSet(MkSet(ePolyObject));
  PolyIter.AddFilter_LayerSet(AllLayers);
  PolyIter.AddFilter_Method(eProcessAll);

  Prim := PolyIter.FirstPCBObject;
  while Prim <> Nil do
  begin
    if Prim.ObjectId = ePolyObject then
    begin
      poly := Prim;
      polyBBCX := (poly.BoundingRectangle.Left + poly.BoundingRectangle.Right) div 2;
      polyBBCY := (poly.BoundingRectangle.Bottom + poly.BoundingRectangle.Top) div 2;

      { Log every polygon visited, regardless of ownership decision. }
      PolyLog.Add('  POLY layer=' + IntToStr(poly.Layer) +
                  '  preBBoxC=(' + FloatToStrF(CoordToMMs(polyBBCX), ffFixed, 10, 3) +
                  ',' + FloatToStrF(CoordToMMs(polyBBCY), ffFixed, 10, 3) + ')' +
                  '  PointCount=' + IntToStr(poly.PointCount));

      if (poly.Component = Nil) and
         PointInRect(polyBBCX, polyBBCY,
                     bx1 - margin, by1 - margin,
                     bx2 + margin, by2 + margin) then
      begin
        key := PrimitiveKey(poly);
        if (DoneSet.IndexOf(key) < 0) and
           IsPrimitiveOwnedBy(OwnerMap, key, chanIdx) then
        begin
          DoneSet.Add(key);
          PolyLog.Add('    -> OWNED+TRANSFORMING  key=' + key);
          pointCount := poly.PointCount;
          for polyIdx := 0 to pointCount - 1 do
          begin
            seg := poly.Segments[polyIdx];
            PolyLog.Add('    pre  S[' + IntToStr(polyIdx) + ']' +
                        '  Kind=' + IntToStr(seg.Kind) +
                        '  vx=' + FloatToStrF(CoordToMMs(seg.vx), ffFixed, 10, 3) +
                        '  vy=' + FloatToStrF(CoordToMMs(seg.vy), ffFixed, 10, 3));
            { 2026-05-23: ARCS-AS-LINES approach. Transform the vertex
              position; FORCE Kind=0 (line) and zero cx/cy. Arc edges
              become straight chords between vertices. We lose curved
              boundaries but the polygon topology is unambiguous
              (no sweep direction to corrupt). For channel-pour
              polygons this is acceptable -- the pour region is
              roughly the same area, just with cut-off corners.

              This bypasses the unknown-field issue: TPolySegment has
              additional fields beyond Kind/vx/vy/cx/cy on AD26 (the
              `angle` we hit earlier is one of them, likely arc sweep
              direction). The seg-record copy doesn't preserve these
              fields correctly, so writing back arcs produces invalid
              sweep directions. Setting Kind=0 sidesteps the problem
              entirely -- line segments have no sweep ambiguity. }
            RotatePointXY(seg.vx, seg.vy, oldCX, oldCY, rotateDeg, tx, ty);
            seg.vx := tx + dX;
            seg.vy := ty + dY;
            seg.Kind := 0;
            seg.cx := 0;
            seg.cy := 0;
            poly.Segments[polyIdx] := seg;
            { READ BACK to verify the write persisted. }
            seg := poly.Segments[polyIdx];
            PolyLog.Add('    post S[' + IntToStr(polyIdx) + ']' +
                        '  Kind=' + IntToStr(seg.Kind) +
                        '  vx=' + FloatToStrF(CoordToMMs(seg.vx), ffFixed, 10, 3) +
                        '  vy=' + FloatToStrF(CoordToMMs(seg.vy), ffFixed, 10, 3) +
                        '  (READ-BACK)');
          end;
          poly.GraphicallyInvalidate;
          PolyLog.Add('    postBBoxC=(' +
                      FloatToStrF(CoordToMMs((poly.BoundingRectangle.Left + poly.BoundingRectangle.Right) div 2), ffFixed, 10, 3) +
                      ',' +
                      FloatToStrF(CoordToMMs((poly.BoundingRectangle.Bottom + poly.BoundingRectangle.Top) div 2), ffFixed, 10, 3) + ')');
        end
        else
          PolyLog.Add('    -> SKIP (DoneSet hit OR not owned by ch' + IntToStr(chanIdx) + ')');
      end
      else
        PolyLog.Add('    -> SKIP (Component<>Nil OR bbox-center outside ch' + IntToStr(chanIdx) + ' area)');
    end;
    Prim := PolyIter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(PolyIter);

  try
    PolyLog.SaveToFile('C:\Users\Public\polygon-move.log');
  except
  end;
  PolyLog.Free;
end;

{ --------------------------------------------------------------------------- }
function ComputeMargin(bx1, by1, bx2, by2 : TCoord) : TCoord;
var
  w_mm, h_mm, big_mm, marg_mm : Double;
begin
  w_mm := CoordToMMs(bx2 - bx1);
  h_mm := CoordToMMs(by2 - by1);
  if w_mm > h_mm then big_mm := w_mm else big_mm := h_mm;
  marg_mm := big_mm * MARGIN_FRACTION;
  if marg_mm < MARGIN_MIN_MM then marg_mm := MARGIN_MIN_MM;
  if marg_mm > MARGIN_MAX_MM then marg_mm := MARGIN_MAX_MM;
  Result := MMsToCoord(marg_mm);
end;

{ ---------------------------------------------------------------------------
  CollectMatchingClasses
  Fill ChanNames (sorted) with component-class names that start with prefix.
--------------------------------------------------------------------------- }
procedure CollectMatchingClasses(Board     : IPCB_Board;
                                 prefix    : String;
                                 ChanNames : TStringList);
var
  Iter : IPCB_BoardIterator;
  Prim : IPCB_Primitive;
  Cls  : IPCB_ObjectClass;
begin
  ChanNames.Clear;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND) and
       (not IsBuiltInComponentClass(Cls)) and
       (AnsiUpperCase(Copy(Cls.Name, 1, Length(prefix))) =
        AnsiUpperCase(prefix)) and
       (CountClassMembers(Board, Cls) > 0) then
    begin
      if ChanNames.Count < MAX_CHANNELS_SAFETY then
        ChanNames.Add(Cls.Name);
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ ---------------------------------------------------------------------------
  SnapSuffixToUnderscore
  Given a candidate suffix, return the longest tail that starts with '_'.
  If no underscore exists in the candidate, returns empty (caller will
  then treat the designator as un-suffixed and match by raw text).

  Example: 'nion_U_DUT1' -> '_U_DUT1'
           'A'           -> ''
           '_X1'         -> '_X1'
--------------------------------------------------------------------------- }
function SnapSuffixToUnderscore(suffix : String) : String;
var
  i, l : Integer;
begin
  Result := '';
  l := Length(suffix);
  for i := 1 to l do
  begin
    if Copy(suffix, i, 1) = '_' then
    begin
      Result := Copy(suffix, i, l - i + 1);
      Exit;
    end;
  end;
end;

{ ---------------------------------------------------------------------------
  DeriveClassSuffix
  v15 (restored from v14-1st, 613d526): derive the per-class designator
  suffix EMPIRICALLY from the longest common trailing substring of all
  component designators in the class.

  Background: Altium's multi-channel compile can decouple the class NAME
  from the per-component channel suffix. Example seen on MotionJigBase
  (2026-05-14 diagnostic): class names are letter-suffixed
  ("U_DUTB" through "U_DUTN") but component designators carry the
  channel INDEX suffix ("_U_DUT1" through "_U_DUT13"). The pre-v14
  assumption suffix = '_' + className produced 0 matches on every
  reset attempt -- which left non-reference channels at their pre-
  script positions, and the polar transform produced the elliptical-
  orbit-growing-as-it-goes-around pattern (every channel landing at
  a different radius from polarO).

  Approach: take any one component in the class as the reference, then
  shrink the common-trailing length against every other component. Snap
  the result to start with '_' so the strip leaves a clean root. Empty
  string is a valid output -- it means "no detectable channel suffix",
  and StripChannelSuffix in that case is a no-op.
--------------------------------------------------------------------------- }
function DeriveClassSuffix(Board : IPCB_Board; Cls : IPCB_ObjectClass) : String;
var
  Iter        : IPCB_BoardIterator;
  Comp        : IPCB_Component;
  firstDesig  : String;
  currentDesig: String;
  haveFirst   : Boolean;
  observedMultiple : Boolean;
  commonLen   : Integer;
  l1, l2, minL, matchLen, i : Integer;
begin
  Result := '';
  firstDesig := '';
  haveFirst := False;
  observedMultiple := False;
  commonLen := 0;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if Cls.IsMember(Comp) then
    begin
      currentDesig := Comp.Name.Text;
      if not haveFirst then
      begin
        firstDesig := currentDesig;
        commonLen := Length(firstDesig);
        haveFirst := True;
      end
      else
      begin
        observedMultiple := True;
        l1 := Length(firstDesig);
        l2 := Length(currentDesig);
        if l1 < l2 then minL := l1 else minL := l2;
        matchLen := 0;
        for i := 0 to minL - 1 do
        begin
          if AnsiUpperCase(Copy(firstDesig, l1 - i, 1)) =
             AnsiUpperCase(Copy(currentDesig, l2 - i, 1)) then
            matchLen := matchLen + 1
          else
            Break;
        end;
        if matchLen < commonLen then commonLen := matchLen;
      end;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  { Single-component channel: commonLen is still Length(firstDesig) because
    the cap-to-matchLen step never ran. The whole designator would be over-
    claimed as the suffix, which is wrong (there is no "common trailing
    substring" without a second sample). Return empty so StripChannelSuffix
    becomes a no-op and the channel matches by raw designator -- which is
    the safest fallback for a configuration the suffix-derivation cannot
    resolve from observation. }
  if haveFirst and observedMultiple and (commonLen > 0) then
    Result := SnapSuffixToUnderscore(
                Copy(firstDesig, Length(firstDesig) - commonLen + 1, commonLen));
end;

{ ---------------------------------------------------------------------------
  StripChannelSuffix
  v15: takes the PRE-DERIVED suffix (use DeriveClassSuffix to compute it
  once per class), not the class name. The suffix already includes its
  leading '_' if any.

  Designator "M4_U_DUT1", suffix "_U_DUT1" -> "M4"
  Designator "R3_U_DUT2", suffix "_U_DUT2" -> "R3"
  Designator "C1_U_DUTB", suffix "_U_DUTB" -> "C1"  (clean class==suffix case)
  If the designator doesn't end with the suffix, returns the designator
  unchanged. Empty suffix is a no-op. Case-insensitive.
--------------------------------------------------------------------------- }
function StripChannelSuffix(designator, classSuffix : String) : String;
var
  desigLen, suffLen : Integer;
begin
  if classSuffix = '' then
  begin
    Result := designator;
    Exit;
  end;
  desigLen := Length(designator);
  suffLen := Length(classSuffix);
  if (desigLen >= suffLen) and
     (AnsiUpperCase(Copy(designator, desigLen - suffLen + 1, suffLen)) =
      AnsiUpperCase(classSuffix)) then
    Result := Copy(designator, 1, desigLen - suffLen)
  else
    Result := designator;
end;

{ ---------------------------------------------------------------------------
  FindMatchingComponent
  v15: takes the reference class's PRE-DERIVED suffix (from DeriveClass-
  Suffix), not the class name.

  Looks through the given class for a component whose "root" designator
  (stripped of the class suffix) matches the target root. Returns Nil if
  not found.
--------------------------------------------------------------------------- }
function FindMatchingComponent(Board : IPCB_Board;
                               Cls : IPCB_ObjectClass;
                               classSuffix : String;
                               targetRoot : String) : IPCB_Component;
var
  Iter : IPCB_BoardIterator;
  Comp : IPCB_Component;
  root : String;
begin
  Result := Nil;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if Cls.IsMember(Comp) then
    begin
      root := StripChannelSuffix(Comp.Name.Text, classSuffix);
      if AnsiUpperCase(root) = AnsiUpperCase(targetRoot) then
      begin
        Result := Comp;
        Break;
      end;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ ---------------------------------------------------------------------------
  ResetChannelsToMatchReference
  For each channel other than the reference, repositions and re-rotates
  every component to match the corresponding component in the reference
  channel.

  "Corresponding" means: same root designator (designator minus the
  channel class suffix). The reference channel's components are read
  once up-front and used as the template.

  After this procedure runs, every channel occupies the same space as
  the reference channel -- they all overlap visually. That is the
  expected intermediate state before the polar array step rotates
  them around the origin.

  Returns the number of components that were successfully matched and
  repositioned. If a target channel has a component whose root designator
  isn't found in the reference, that component is skipped (warning in
  the final summary).
--------------------------------------------------------------------------- }
function ResetChannelsToMatchReference(Board     : IPCB_Board;
                                       RefCls    : IPCB_ObjectClass;
                                       RefClsName : String;
                                       ChanNames : TStringList) : Integer;
var
  CompIter : IPCB_BoardIterator;
  Comp, refComp : IPCB_Component;
  i : Integer;
  otherClsName : String;
  otherCls : IPCB_ObjectClass;
  root : String;
  matched : Integer;
  ChanSuffixes : TStringList;
  refSuffix, otherSuffix : String;
begin
  matched := 0;

  { v15: pre-derive the per-class designator suffix EMPIRICALLY, once per
    class. The class name and the per-component suffix are not always the
    same -- Altium can use the channel INDEX in designators while naming
    the class for the sheet symbol. See DeriveClassSuffix docs. }
  ChanSuffixes := TStringList.Create;
  for i := 0 to ChanNames.Count - 1 do
  begin
    otherCls := FindClassByName(Board, ChanNames[i]);
    if otherCls <> Nil then
      ChanSuffixes.Add(DeriveClassSuffix(Board, otherCls))
    else
      ChanSuffixes.Add('');
  end;
  refSuffix := ChanSuffixes[0];

  { For each non-reference channel }
  for i := 1 to ChanNames.Count - 1 do
  begin
    otherClsName := ChanNames[i];
    otherCls := FindClassByName(Board, otherClsName);
    if otherCls = Nil then Continue;
    otherSuffix := ChanSuffixes[i];

    { Walk every component in this other channel and copy the reference
      component's position and rotation into it. }
    CompIter := Board.BoardIterator_Create;
    CompIter.AddFilter_ObjectSet(MkSet(eComponentObject));
    CompIter.AddFilter_LayerSet(AllLayers);
    CompIter.AddFilter_Method(eProcessAll);

    Comp := CompIter.FirstPCBObject;
    while Comp <> Nil do
    begin
      if otherCls.IsMember(Comp) then
      begin
        root := StripChannelSuffix(Comp.Name.Text, otherSuffix);
        refComp := FindMatchingComponent(Board, RefCls, refSuffix, root);
        if refComp <> Nil then
        begin
          { Copy absolute position and rotation from the reference
            component. The whole channel ends up sitting exactly where
            the reference sits. }
          Comp.X := refComp.X;
          Comp.Y := refComp.Y;
          Comp.Rotation := refComp.Rotation;
          Comp.Layer := refComp.Layer;
          Comp.GraphicallyInvalidate;
          matched := matched + 1;
        end;
      end;
      Comp := CompIter.NextPCBObject;
    end;
    Board.BoardIterator_Destroy(CompIter);
  end;

  ChanSuffixes.Free;
  Result := matched;
end;

{ ---------------------------------------------------------------------------
  FindSelectedComponent
  If the user has a component (or a primitive belonging to one) selected
  before running the script, return it. This skips the click prompt for
  users who already know which component to use. Returns Nil if nothing
  useful is selected.

  Note: Board.SelectecObjectCount / SelectecObject[i] uses the Altium
  type-library's well-known typo (sic). The whole body is wrapped in
  try/except so that on any Altium build that doesn't expose these
  properties (or where access raises) the function safely returns Nil
  and the caller falls through to the click prompt -- the script keeps
  working, the user just doesn't get the selected-skip-the-click
  shortcut.
--------------------------------------------------------------------------- }
function FindSelectedComponent(Board : IPCB_Board) : IPCB_Component;
var
  i, n : Integer;
  Prim : IPCB_Primitive;
  fallbackComp : IPCB_Component;
begin
  Result := Nil;
  fallbackComp := Nil;

  try
    n := Board.SelectecObjectCount;
  except
    n := 0;                  { property absent on this Altium build }
  end;

  for i := 0 to n - 1 do
  begin
    Prim := Nil;
    try
      Prim := Board.SelectecObject[i];
    except
      Prim := Nil;
    end;
    if Prim = Nil then Continue;

    if Prim.ObjectId = eComponentObject then
    begin
      Result := Prim;
      Exit;
    end;

    if (fallbackComp = Nil) and (Prim.Component <> Nil) then
      fallbackComp := Prim.Component;
  end;

  Result := fallbackComp;
end;

{ ---------------------------------------------------------------------------
  FindComponentAtLocation
  Returns the component whose bounding box contains (X, Y). If none
  contains the click, returns the nearest component within a reasonable
  search radius. Returns Nil if nothing is near.
--------------------------------------------------------------------------- }
function FindComponentAtLocation(Board : IPCB_Board;
                                 X     : TCoord;
                                 Y     : TCoord) : IPCB_Component;
var
  Iter     : IPCB_BoardIterator;
  Comp     : IPCB_Component;
  bestComp : IPCB_Component;
  bestDist : Double;
  dist     : Double;
begin
  bestComp := Nil;
  bestDist := 1e30;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if (X >= Comp.BoundingRectangle.Left)   and
       (X <= Comp.BoundingRectangle.Right)  and
       (Y >= Comp.BoundingRectangle.Bottom) and
       (Y <= Comp.BoundingRectangle.Top) then
    begin
      { Direct hit -- prefer over any distance-based match. }
      bestComp := Comp;
      bestDist := -1;
      Break;
    end;
    dist := Sqrt(Sqr(CoordToMMs(Comp.X - X)) + Sqr(CoordToMMs(Comp.Y - Y)));
    if dist < bestDist then
    begin
      bestComp := Comp;
      bestDist := dist;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
  Result := bestComp;
end;

{ ---------------------------------------------------------------------------
  FindChannelClassForComponent
  Walks all component classes and returns the name of the most-specific
  one the given component belongs to. In multi-channel designs the
  channel class is usually the longest-named class a component is a
  member of (e.g. "U_DUTB" rather than the generic "All Components").
  Returns '' if the component has no channel class.
--------------------------------------------------------------------------- }
function FindChannelClassForComponent(Board : IPCB_Board;
                                      Comp  : IPCB_Component) : String;
var
  Iter         : IPCB_BoardIterator;
  Prim         : IPCB_Primitive;
  Cls          : IPCB_ObjectClass;
  longestMatch : String;
begin
  longestMatch := '';

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND) and
       (not IsBuiltInComponentClass(Cls)) and
       Cls.IsMember(Comp) then
    begin
      if Length(Cls.Name) > Length(longestMatch) then
        longestMatch := Cls.Name;
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
  Result := longestMatch;
end;

{ ---------------------------------------------------------------------------
  DerivePrefixFromReference
  Given the reference class name (e.g. "U_DUTB"), finds the longest
  prefix of that name that ALSO matches at least one OTHER component
  class on the board. For a set [U_DUTB, U_DUTC, U_DUTD] this returns
  "U_DUT". Returns '' if no sibling class shares any prefix of the
  reference name.
--------------------------------------------------------------------------- }
function DerivePrefixFromReference(Board   : IPCB_Board;
                                   refName : String)    : String;
var
  Iter       : IPCB_BoardIterator;
  Prim       : IPCB_Primitive;
  Cls        : IPCB_ObjectClass;
  AllClasses : TStringList;
  i, k       : Integer;
  cand       : String;
  found      : Boolean;
begin
  Result := '';
  AllClasses := TStringList.Create;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND) and
       (not IsBuiltInComponentClass(Cls)) and
       (AnsiUpperCase(Cls.Name) <> AnsiUpperCase(refName)) and
       (CountClassMembers(Board, Cls) > 0) then
      AllClasses.Add(Cls.Name);
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  { Try longest prefix first; first hit wins. }
  for k := Length(refName) - 1 downto 1 do
  begin
    cand := Copy(refName, 1, k);
    found := False;
    for i := 0 to AllClasses.Count - 1 do
    begin
      if AnsiUpperCase(Copy(AllClasses[i], 1, k)) = AnsiUpperCase(cand) then
      begin
        found := True;
        Break;
      end;
    end;
    if found then
    begin
      Result := cand;
      Break;
    end;
  end;

  AllClasses.Free;
end;

{ ---------------------------------------------------------------------------
  SnapshotChannelBBoxes
  Records each channel's pre-reset bounding box and component count
  into BBoxes (one CSV line per channel index). Must be called BEFORE
  ResetChannelsToMatchReference runs -- the whole point is to capture
  the state of the board as the user laid it out, so the polar step
  can later transform free primitives that were not moved by the
  reset step.

  CSV format per entry: "minX,minY,maxX,maxY,cx,cy,count" (TCoord
  integers as strings, count as integer).

  Index 0 of BBoxes corresponds to the reference channel (which is
  never reset, so its snapshot equals its post-reset state).
--------------------------------------------------------------------------- }
procedure SnapshotChannelBBoxes(Board     : IPCB_Board;
                                ChanNames : TStringList;
                                BBoxes    : TStringList);
var
  i, compCount : Integer;
  minX, minY, maxX, maxY, cx, cy : TCoord;
  Cls : IPCB_ObjectClass;
  csv : String;
begin
  BBoxes.Clear;
  for i := 0 to ChanNames.Count - 1 do
  begin
    Cls := FindClassByName(Board, ChanNames[i]);
    if Cls = Nil then
    begin
      BBoxes.Add('0,0,0,0,0,0,0');
      Continue;
    end;
    ComputeChannelBBox(Board, Cls, minX, minY, maxX, maxY, compCount);
    cx := (minX + maxX) div 2;
    cy := (minY + maxY) div 2;
    csv := IntToStr(minX) + ',' + IntToStr(minY) + ',' +
           IntToStr(maxX) + ',' + IntToStr(maxY) + ',' +
           IntToStr(cx)   + ',' + IntToStr(cy)   + ',' +
           IntToStr(compCount);
    BBoxes.Add(csv);
  end;
end;

{ ---------------------------------------------------------------------------
  GetBBoxFromSnapshot
  Parses entry idx of BBoxes back into TCoord values. Returns
  compCount = 0 if the snapshot row is missing or malformed (caller
  should skip that channel).

  CSV is parsed manually using Pos / Copy rather than via
  TStringList.DelimitedText -- DelphiScript on older Altium builds
  does not always expose the StrictDelimiter property, and a missing
  property raises a runtime error rather than a compile-time one.
  Manual parsing also avoids the documented "DelimitedText treats
  whitespace as a delimiter" quirk in non-strict mode.
--------------------------------------------------------------------------- }
procedure GetBBoxFromSnapshot(BBoxes : TStringList;
                              idx    : Integer;
                              var minX, minY, maxX, maxY, cx, cy : TCoord;
                              var compCount : Integer);
var
  csv, token : String;
  p, fieldIdx : Integer;
  vals : array[0..6] of Integer;
begin
  minX := 0; minY := 0; maxX := 0; maxY := 0;
  cx   := 0; cy   := 0; compCount := 0;

  if (idx < 0) or (idx >= BBoxes.Count) then Exit;

  for fieldIdx := 0 to 6 do vals[fieldIdx] := 0;

  csv := BBoxes[idx];
  fieldIdx := 0;

  { Walk the CSV one comma at a time. After the loop, csv holds the
    last (un-terminated) field. Stops at 7 fields to avoid overflow if
    the snapshot row is malformed and contains extra commas. }
  while (Length(csv) > 0) and (fieldIdx < 7) do
  begin
    p := Pos(',', csv);
    if p = 0 then
    begin
      token := csv;
      csv := '';
    end
    else
    begin
      token := Copy(csv, 1, p - 1);
      csv := Copy(csv, p + 1, Length(csv) - p);
    end;
    vals[fieldIdx] := StrToIntDef(Trim(token), 0);
    fieldIdx := fieldIdx + 1;
  end;

  if fieldIdx < 7 then Exit;  { malformed -- leave outputs at 0 }

  minX      := vals[0];
  minY      := vals[1];
  maxX      := vals[2];
  maxY      := vals[3];
  cx        := vals[4];
  cy        := vals[5];
  compCount := vals[6];
end;

{ ---------------------------------------------------------------------------
  BuildPrimitiveOwnership
  v16 (restored from v14-1st, 613d526): one-time pre-pass over every free
  primitive on the board. For each, assign to the nearest pre-script
  channel centre (Euclidean distance in mm to avoid TCoord^2 overflow:
  TCoord is int32 nm, channel pitches of ~100 mm squared overflow 32-bit
  signed). Then validate the primitive falls inside that channel's bbox+
  margin -- if not, the primitive is a global feature (board outline
  text, mounting-hole keep-out fills, etc.) and no channel owns it.

  Result is stored as 'PrimitiveKey=chanIdx' lines in OwnerMap, looked up
  later by TransformChannelFreePrimitives via IsPrimitiveOwnedBy.

  Must run BEFORE the reset step -- only then are the channels at their
  user-placed pre-script positions, where each channel's tracks really
  do sit inside that channel's bbox.

  PreBBoxes : the CSV snapshot built by SnapshotChannelBBoxes.
  OwnerMap  : pre-allocated TStringList; cleared and refilled.

  Limitations: nearest-centre attribution can misclassify a primitive
  that sits closer to a NEIGHBOUR's pre-script centre than to its own
  channel's centre. PointInRect-against-neighbour-bbox+margin may pass
  (-> primitive moves with the neighbour, wrong visually) or fail (->
  primitive has no owner, stays put as an orphan). For radially-
  symmetric pre-script layouts both modes are rare; for arbitrary
  user-placed layouts they show up as a small number of stragglers.
--------------------------------------------------------------------------- }
procedure BuildPrimitiveOwnership(Board     : IPCB_Board;
                                  PreBBoxes : TStringList;
                                  OwnerMap  : TStringList);
var
  Iter        : IPCB_BoardIterator;
  Prim        : IPCB_Primitive;
  primX, primY : TCoord;
  i, bestI    : Integer;
  preMinX, preMinY, preMaxX, preMaxY, preCX, preCY : TCoord;
  preCount    : Integer;
  dxm, dym, distSq, bestDistSq : Double;
  bestMinX, bestMinY, bestMaxX, bestMaxY : TCoord;
  margin      : TCoord;
  key         : String;
begin
  OwnerMap.Clear;
  OwnerMap.Sorted := True;
  OwnerMap.Duplicates := dupIgnore;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject, eViaObject, eArcObject,
                                  eFillObject, eTextObject, ePadObject,
                                  ePolyObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    if (Prim.Component = Nil) and PrimitiveCentroidXY(Prim, primX, primY) then
    begin
      { Find the nearest channel centre. Distance squared in mm-Double
        space to avoid TCoord^2 overflow. }
      bestI := -1;
      bestDistSq := 0;
      bestMinX := 0; bestMinY := 0; bestMaxX := 0; bestMaxY := 0;
      for i := 0 to PreBBoxes.Count - 1 do
      begin
        GetBBoxFromSnapshot(PreBBoxes, i,
                            preMinX, preMinY, preMaxX, preMaxY,
                            preCX, preCY, preCount);
        if preCount > 0 then
        begin
          dxm := CoordToMMs(primX - preCX);
          dym := CoordToMMs(primY - preCY);
          distSq := (dxm * dxm) + (dym * dym);
          if (bestI < 0) or (distSq < bestDistSq) then
          begin
            bestDistSq := distSq;
            bestI := i;
            bestMinX := preMinX; bestMinY := preMinY;
            bestMaxX := preMaxX; bestMaxY := preMaxY;
          end;
        end;
      end;

      { Confirm the primitive is inside the winning channel's bbox+margin.
        If not, it's a global primitive and no channel owns it. }
      if bestI >= 0 then
      begin
        margin := ComputeMargin(bestMinX, bestMinY, bestMaxX, bestMaxY);
        if PointInRect(primX, primY,
                       bestMinX - margin, bestMinY - margin,
                       bestMaxX + margin, bestMaxY + margin) then
        begin
          key := PrimitiveKey(Prim);
          OwnerMap.Add(key + '=' + IntToStr(bestI));
        end;
      end;
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ ===========================================================================
  ENTRY POINT
=========================================================================== }
procedure ArrangeChannelsInPolarArray;
var
  Board     : IPCB_Board;
  Cls       : IPCB_ObjectClass;

  ChanNames      : TStringList;  { matching channel class names }
  DoneSet        : TStringList;
  PreBBoxes      : TStringList;  { pre-reset bbox snapshot per channel idx }
  OwnerMap       : TStringList;  { v16: 'primKey=chanIdx' per free primitive }

  i, N, compCount, refIdx : Integer;
  prefix, inputStr, refClassName : String;
  cx_mm, cy_mm : Double;
  CX, CY    : TCoord;
  refX, refY : TCoord;
  refComp   : IPCB_Component;
  rotateDeg : Double;
  newCX, newCY : TCoord;
  minX, minY, maxX, maxY, margin : TCoord;
  refCX, refCY : TCoord;
  refR_mm : Double;
  summary : String;
  resetMatched : Integer;
  preMinX, preMinY, preMaxX, preMaxY : TCoord;
  preCX, preCY : TCoord;
  preCount : Integer;
begin
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.');
    Exit;
  end;

  { ---- Step 1: Pick a component in the reference channel ----
    First check whether the user already has a component (or a primitive
    of one) selected -- if so, use that and skip the click prompt.
    Otherwise put Altium into crosshair mode and let the user click on
    or near any component in the channel they want to use as the
    reference layout (e.g. a resistor in U_DUTB). }
  refComp := FindSelectedComponent(Board);

  if refComp = Nil then
  begin
    ShowMessage('Step 1 of 2: Click on any COMPONENT in the REFERENCE channel.' + #13#10 + #13#10 +
                'The component you click tells the script which channel is' + #13#10 +
                'the reference. Every other channel in the detected set will' + #13#10 +
                'be normalised to match the reference before the polar array' + #13#10 +
                'is applied.' + #13#10 + #13#10 +
                'Tip: click directly on a component pad or body for best results.' + #13#10 +
                'Tip: you can also pre-select a component before running this script.');

    if not Board.ChooseLocation(refX, refY, 'Click a component in the reference channel') then
      Exit;

    refComp := FindComponentAtLocation(Board, refX, refY);
    if refComp = Nil then
    begin
      ShowMessage('ERROR: No component found near the clicked location.' + #13#10 +
                  'Click closer to a component in the reference channel.');
      Exit;
    end;
  end;

  refClassName := FindChannelClassForComponent(Board, refComp);
  if Trim(refClassName) = '' then
  begin
    ShowMessage('ERROR: The clicked component (' + refComp.Name.Text + ')' + #13#10 +
                'does not belong to any USER-defined component class.' + #13#10 + #13#10 +
                'Built-in classes (All Components / Inside Board /' + #13#10 +
                'Outside Board Components) are skipped.' + #13#10 + #13#10 +
                'Has the multi-channel project been compiled?' + #13#10 +
                '(Project > Compile PCB Project regenerates channel classes.)');
    Exit;
  end;

  prefix := DerivePrefixFromReference(Board, refClassName);
  if prefix = '' then
  begin
    ShowMessage('ERROR: Could not derive a channel prefix from "' +
                refClassName + '".' + #13#10 +
                'No other component class on this board shares any prefix' + #13#10 +
                'with the clicked component''s class. A polar array needs' + #13#10 +
                'at least 2 sibling channels.');
    Exit;
  end;

  { ---- Step 2: Collect matching classes, put reference first ---- }
  ChanNames := TStringList.Create;
  ChanNames.Sorted := True;
  ChanNames.Duplicates := dupIgnore;

  CollectMatchingClasses(Board, prefix, ChanNames);

  N := ChanNames.Count;
  if N < 2 then
  begin
    ShowMessage('Only ' + IntToStr(N) + ' channel(s) matched prefix "' +
                prefix + '" (derived from "' + refClassName + '").' + #13#10 +
                'Need at least 2 to form a polar array.');
    ChanNames.Free;
    Exit;
  end;

  { Move the clicked reference class to index 0. Rest stay alphabetical. }
  refIdx := ChanNames.IndexOf(refClassName);
  if refIdx < 0 then
  begin
    ShowMessage('ERROR: Reference class "' + refClassName +
                '" did not appear in the matched set.' + #13#10 +
                'This should not happen -- check that the clicked component''s' + #13#10 +
                'class name matches a sibling class on the board exactly.');
    ChanNames.Free;
    Exit;
  end;
  if refIdx > 0 then
  begin
    ChanNames.Sorted := False;
    ChanNames.Move(refIdx, 0);
  end;

  { ---- Step 3: Ask for origin by interactive click ----
    Board.ChooseLocation puts Altium into crosshair mode with a status-bar
    prompt. The user clicks on the polar centre (snapping to their polar
    grid if one is enabled). If the user presses Escape, ChooseLocation
    returns False and we fall back to typed input defaulting to (0, 0). }
  if MessageDlg(
       'Step 2 of 2: Click the polar origin point on the PCB.' + #13#10 + #13#10 +
       'If you have a Polar Grid defined, enable snap and click near' + #13#10 +
       'its centre -- Altium will snap to the exact origin.' + #13#10 + #13#10 +
       'Yes = click to pick origin on PCB' + #13#10 +
       'No  = type coordinates manually',
       mtConfirmation, mbYesNo, 0) = mrYes then
  begin
    if not Board.ChooseLocation(CX, CY, 'Click the polar origin point') then
    begin
      ChanNames.Free;
      Exit;
    end;
    cx_mm := CoordToMMs(CX);
    cy_mm := CoordToMMs(CY);
  end
  else
  begin
    { Fall back to typed input with 0,0 defaults }
    inputStr := InputBox('Polar Channel Array - Origin',
      'Polar origin X (mm):', '0');
    if Trim(inputStr) = '' then begin ChanNames.Free; Exit; end;
    cx_mm := StrToFloatDef(inputStr, 0.0);

    inputStr := InputBox('Polar Channel Array - Origin',
      'Polar origin Y (mm):', '0');
    if Trim(inputStr) = '' then begin ChanNames.Free; Exit; end;
    cy_mm := StrToFloatDef(inputStr, 0.0);

    CX := MMsToCoord(cx_mm);
    CY := MMsToCoord(cy_mm);
  end;

  { ---- Step 4: Measure reference channel ---- }
  Cls := FindClassByName(Board, ChanNames[0]);
  if Cls = Nil then
  begin
    ShowMessage('ERROR: Could not re-find reference class ' + ChanNames[0]);
    ChanNames.Free;
    Exit;
  end;

  ComputeChannelBBox(Board, Cls, minX, minY, maxX, maxY, compCount);
  if compCount = 0 then
  begin
    ShowMessage('ERROR: Reference channel has no components.');
    ChanNames.Free;
    Exit;
  end;

  refCX := (minX + maxX) div 2;
  refCY := (minY + maxY) div 2;
  refR_mm := Sqrt(Sqr(CoordToMMs(refCX - CX)) + Sqr(CoordToMMs(refCY - CY)));

  if refR_mm < 0.01 then
  begin
    ShowMessage('WARNING: Reference channel bbox centre coincides with' + #13#10 +
                'the polar origin. There is no radial offset to propagate.' + #13#10 +
                'Move the reference channel away from the origin, or choose' + #13#10 +
                'a different origin point.');
    ChanNames.Free;
    Exit;
  end;

  { ---- Step 5: Reset always runs ----
    All non-reference channels are normalised to match the reference
    channel (ChanNames[0] = class of the clicked component) before the
    polar array is applied. This guarantees a clean starting state on
    every run. }
  resetMatched := 0;

  { ---- Step 6: Confirmation ---- }
  summary := 'Polar Channel Array -- Summary' + #13#10 + #13#10 +
             'Reference (clicked): ' + refClassName + #13#10 +
             'Derived prefix: "' + prefix + '"' + #13#10 +
             'Channel count: ' + IntToStr(N) + #13#10 +
             'Channels (reference first): ';
  for i := 0 to N - 1 do
  begin
    if i > 0 then summary := summary + ', ';
    summary := summary + ChanNames[i];
  end;
  summary := summary + #13#10 + #13#10;

  summary := summary +
             'Reset: ENABLED (all channels will snap to reference first)' + #13#10 + #13#10;

  summary := summary +
             'Reference bbox centre: (' +
               FloatToStrF(CoordToMMs(refCX), ffFixed, 10, 3) + ', ' +
               FloatToStrF(CoordToMMs(refCY), ffFixed, 10, 3) + ') mm' + #13#10 +
             'Polar origin: (' +
               FloatToStrF(cx_mm, ffFixed, 10, 3) + ', ' +
               FloatToStrF(cy_mm, ffFixed, 10, 3) + ') mm' + #13#10 +
             'Derived radius: ' +
               FloatToStrF(refR_mm, ffFixed, 10, 3) + ' mm' + #13#10 +
             'Angular step: ' +
               FloatToStrF(360.0 / N, ffFixed, 10, 3) + ' deg' + #13#10 + #13#10 +
             'Polygons will NOT be transformed -- re-pour after.' + #13#10 + #13#10 +
             'Proceed?';

  if MessageDlg(summary, mtConfirmation, mbYesNo, 0) <> mrYes then
  begin
    ChanNames.Free;
    Exit;
  end;

  { ---- Step 7a: Snapshot each channel's pre-reset bbox ----
    Captures bbox per channel BEFORE the reset step moves components.
    The polar step needs this so free primitives (tracks / vias / etc.)
    can be transformed using the channel's true original location, not
    the reference location they collapse to after reset. v12 bug:
    polar step used post-reset bbox for everything; free primitives
    ended up at random positions. }
  PreBBoxes := TStringList.Create;
  SnapshotChannelBBoxes(Board, ChanNames, PreBBoxes);

  { ---- Step 7a-bis: Build per-primitive ownership map ----
    v16: assign every free primitive on the board to its nearest pre-script
    channel (validated by bbox+margin). Must run BEFORE the reset step,
    while channels are still at their user-placed positions and free
    primitives align with their owning channel's pre-script bbox. The
    polar loop then uses OwnerMap to refuse cross-claims when adjacent
    channels' bbox+margin regions overlap (the MotionJigBase 12-channel
    starburst symptom). See v16 header changelog for full motivation. }
  OwnerMap := TStringList.Create;
  BuildPrimitiveOwnership(Board, PreBBoxes, OwnerMap);

  { ---- Step 7b: Apply reset ---- }
  PCBServer.PreProcess;
  resetMatched := ResetChannelsToMatchReference(Board, Cls, ChanNames[0], ChanNames);
  PCBServer.PostProcess;
  Board.GraphicallyInvalidate;

  { After reset, re-measure the reference bbox. It shouldn't have
    changed (reference components weren't touched) but recomputing is
    cheap and keeps refCX/refCY honest. }
  ComputeChannelBBox(Board, Cls, minX, minY, maxX, maxY, compCount);
  refCX := (minX + maxX) div 2;
  refCY := (minY + maxY) div 2;

  { ---- Step 8: Apply polar transforms ---- }
  DoneSet := TStringList.Create;
  DoneSet.Sorted := True;
  DoneSet.Duplicates := dupIgnore;

  PCBServer.PreProcess;

  { Skip i=0 (reference channel) -- no transformation applied }
  for i := 1 to N - 1 do
  begin
    Cls := FindClassByName(Board, ChanNames[i]);
    if Cls = Nil then Continue;

    rotateDeg := i * (360.0 / N);

    { Components: after reset, channel i's components sit on top of the
      reference channel's components. Old centre is therefore the
      reference bbox centre; new centre is that centre rotated around
      the polar origin. }
    RotatePointXY(refCX, refCY, CX, CY, rotateDeg, newCX, newCY);
    TransformChannelComponents(Board, Cls,
                                refCX, refCY, newCX, newCY, rotateDeg);

    { Free primitives: spatial query region is the channel's original
      (pre-reset) bbox -- that's where the tracks actually sit, because
      the reset step did not move them. The rotation pivot is the
      channel's own pre-reset centre (preC), so the track rotates
      rigidly around its own footprint. The destination is the
      COMPONENT destination (newC = rotate(refC) around the polar
      origin), NOT rotate(preC) -- so that after the transform the
      tracks land alongside the components at the channel's polar
      slot. v13 used rotate(preC) here, which placed tracks at the
      rotated copy of the channel's original arbitrary location and
      pulled them away from their components. See v14 changelog at
      the top of this file for the worked geometry. }
    GetBBoxFromSnapshot(PreBBoxes, i,
                        preMinX, preMinY, preMaxX, preMaxY,
                        preCX, preCY, preCount);
    if preCount > 0 then
    begin
      margin := ComputeMargin(preMinX, preMinY, preMaxX, preMaxY);
      TransformChannelFreePrimitives(Board, DoneSet, OwnerMap, i,
                                      preMinX, preMinY, preMaxX, preMaxY, margin,
                                      preCX, preCY, newCX, newCY, rotateDeg);
    end;
  end;

  PCBServer.PostProcess;

  Board.GraphicallyInvalidate;

  ShowMessage('Done: ' + IntToStr(N) + ' channels arranged on a ' +
              FloatToStrF(refR_mm, ffFixed, 10, 3) + ' mm radius circle.' + #13#10 +
              IntToStr(DoneSet.Count) + ' free primitives transformed.' + #13#10 +
              'Reset snapped ' + IntToStr(resetMatched) + ' components to reference.' + #13#10 +
              'Reference ' + ChanNames[0] + ' was not moved.' + #13#10 + #13#10 +
              'Next: Tools > Polygon Pours > Repour All, then run DRC.');

  DoneSet.Free;
  PreBBoxes.Free;
  OwnerMap.Free;
  ChanNames.Free;
end;
