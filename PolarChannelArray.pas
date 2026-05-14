{*******************************************************************************
  PolarChannelArray.pas  -- REVISED v14
  Altium DelphiScript -- Arrange channel "rooms" in a circular (polar) array.

  ================================================================
  WHAT CHANGED FROM v13
  ================================================================
  Bug fix: ResetChannelsToMatchReference returned 0 matches on
  boards where Altium's multi-channel compile decoupled the class
  NAME from the per-component designator suffix.

  Concrete failure (MotionJigBase, 2026-05-14): channel classes
  named "U_DUTB".."U_DUTN" (letter-suffixed), but the components
  inside them used the channel INDEX in their designators --
  "M4_U_DUT1", "R3_U_DUT2", etc. The old v13 assumption
  suffix = '_' + className searched for "_U_DUTB" at the end of
  "M4_U_DUT1", never found it, every match attempt missed, all 12
  non-reference channels reset 0 components, the polar transform
  ran on free primitives only, and the components stayed in their
  pre-script layout positions.

  Fix: derive the per-class designator suffix EMPIRICALLY from the
  longest common trailing substring of components in that class,
  snapped to start with '_'. The suffix is computed once per class
  at the start of ResetChannelsToMatchReference and stored in a
  parallel TStringList. StripChannelSuffix and FindMatchingComponent
  now take the pre-derived suffix instead of recomputing it from
  the class name. Robust to whatever naming convention Altium's
  multi-channel compile chose; works on the previous-known case
  (class==suffix) and the newly-found one (class!=suffix).

  Diagnostic that surfaced the bug: PolarChannelArray-Diagnostic.pas
  (kept in repo for future debugging of similar mismatches).

  ================================================================
  WHAT CHANGED FROM v12
  ================================================================
  Bug fix: free tracks / vias / arcs / fills / text / free pads
  belonging to non-reference channels were ending up at random
  positions after the polar array ran.

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

  Fix: snapshot each channel's bounding box BEFORE the reset step
  runs. In the polar step, free-primitive transforms use the
  channel's pre-reset bounding box for both the spatial query
  region and the rotation pivot. Components still use the post-
  reset (= reference) bounding box, because that's where they
  are when the polar step runs.

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
      Result := 'A:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.XCenter) + ',' + IntToStr(Prim.YCenter);
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
  OwnerMap.Sorted is True (verified API in this corpus: see DoneSet usage
  at line ~1644 with the same Sorted+IndexOf pattern).

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

{ ---------------------------------------------------------------------------
  TransformChannelFreePrimitives
  v14.1: changed from procedure to function. Returns the number of free
  primitives actually transformed in this call (excludes DoneSet-deduped
  and ownership-skipped). Per-channel transform count is the main diagnostic
  signal for the cross-claim hypothesis -- if owned and transformed counts
  don't match across channels, classification or rotation is dropping work.
--------------------------------------------------------------------------- }
function TransformChannelFreePrimitives(Board    : IPCB_Board;
                                        DoneSet  : TStringList;
                                        OwnerMap : TStringList;
                                        chanIdx  : Integer;
                                        bx1, by1, bx2, by2 : TCoord;
                                        margin  : TCoord;
                                        oldCX, oldCY : TCoord;
                                        newCX, newCY : TCoord;
                                        rotateDeg    : Double) : Integer;
var
  Iter : IPCB_SpatialIterator;
  Prim : IPCB_Primitive;
  dX, dY : TCoord;
  tx, ty, tx2, ty2 : TCoord;
  fillCX, fillCY, fillHW, fillHH : TCoord;
  key  : String;
  xformedCount : Integer;

  track : IPCB_Track;
  via   : IPCB_Via;
  arc   : IPCB_Arc;
  txt   : IPCB_Text;
  pad   : IPCB_Pad;
begin
  xformedCount := 0;
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
            xformedCount := xformedCount + 1;
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
            xformedCount := xformedCount + 1;
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
            xformedCount := xformedCount + 1;
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
              xformedCount := xformedCount + 1;
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
            xformedCount := xformedCount + 1;
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
            xformedCount := xformedCount + 1;
          end;
        end;
      end;

    end; { case }

    Prim := Iter.NextPCBObject;
  end; { while }

  Board.SpatialIterator_Destroy(Iter);
  Result := xformedCount;
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
  If no underscore exists in the candidate, returns empty (caller will then
  treat the designator as un-suffixed and match by raw text).

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
  v14: derive the per-class designator suffix EMPIRICALLY from the longest
  common trailing substring of all component designators in the class.

  Background: Altium's multi-channel compile can decouple the class NAME
  from the per-component channel suffix. Example seen on MotionJigBase
  (2026-05-14 diagnostic): class names are letter-suffixed ("U_DUTB"..
  "U_DUTN") but component designators carry the channel INDEX suffix
  ("_U_DUT1".."_U_DUT13"). The old v13 assumption suffix='_'+className
  produced 0 matches on every reset attempt.

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
  commonLen   : Integer;
  l1, l2, minL, matchLen, i : Integer;
begin
  Result := '';
  firstDesig := '';
  haveFirst := False;
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

  if haveFirst and (commonLen > 0) then
    Result := SnapSuffixToUnderscore(
                Copy(firstDesig, Length(firstDesig) - commonLen + 1, commonLen));
end;

{ ---------------------------------------------------------------------------
  StripChannelSuffix
  v14: takes the PRE-DERIVED suffix (use DeriveClassSuffix to compute it
  once per class), not the class name. The suffix already includes its
  leading '_' if any.

  Designator "M4_U_DUT1", suffix "_U_DUT1" -> "M4"
  Designator "R3_U_DUT2", suffix "_U_DUT2" -> "R3"
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
  v14: takes the reference class's PRE-DERIVED suffix (from DeriveClass-
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

  { v14: pre-derive the per-class designator suffix EMPIRICALLY, once per
    class. The class name and the per-component suffix are not always the
    same (Altium can use the channel INDEX in designators while naming the
    class for the sheet symbol -- see DeriveClassSuffix docs). }
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
  CountOwnedByChannel
  v14.1 diagnostic: scan OwnerMap and count entries owned by chanIdx.
  Each entry is 'key=chanIdx', so we test the suffix.
--------------------------------------------------------------------------- }
function CountOwnedByChannel(OwnerMap : TStringList; chanIdx : Integer) : Integer;
var
  suffix : String;
  i, suffLen, count, sLen : Integer;
  s : String;
begin
  suffix := '=' + IntToStr(chanIdx);
  suffLen := Length(suffix);
  count := 0;
  for i := 0 to OwnerMap.Count - 1 do
  begin
    s := OwnerMap[i];
    sLen := Length(s);
    if (sLen >= suffLen) and
       (Copy(s, sLen - suffLen + 1, suffLen) = suffix) then
      count := count + 1;
  end;
  Result := count;
end;

{ ---------------------------------------------------------------------------
  BuildPrimitiveOwnership
  v14 fix for the bbox-overlap cross-claim hazard: when the pre-script
  channel layout is tight (channels packed in a row with small gaps),
  channel i's bbox+margin overlaps channel j's, and the spatial iterator
  for channel i grabs primitives that visually belong to channel j. With
  DoneSet dedup, only ONE channel claims each primitive -- but it's
  whichever happens to iterate first, NOT necessarily the right one. The
  result is the starburst / fan duplication seen on MotionJigBase 2026-05-14.

  Fix: do a one-time pre-pass over every free primitive on the board,
  assign each to the nearest pre-script channel center (Euclidean distance
  in mm to avoid TCoord^2 overflow), reject any whose nearest is still
  outside that channel's bbox+margin (= it's a global primitive, not in
  any channel). Store as 'PrimitiveKey=chanIdx' lines in OwnerMap, looked
  up later by TransformChannelFreePrimitives.

  PreBBoxes : the CSV snapshot built by SnapshotChannelBBoxes.
  OwnerMap  : preallocated TStringList; cleared and refilled.

  Lives here (after GetBBoxFromSnapshot) because Pascal compilers need
  callees declared before callers; GetBBoxFromSnapshot is used inside.
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
                                  eFillObject, eTextObject, ePadObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    if (Prim.Component = Nil) and PrimitiveCentroidXY(Prim, primX, primY) then
    begin
      { Find the nearest channel center. Distance squared in mm-Double
        space to avoid TCoord^2 overflow (TCoord is int32, channel pitches
        of ~100 mm squared overflow 32-bit signed). }
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
  OwnerMap       : TStringList;  { v14: 'primKey=chanIdx' per free primitive }
  DiagLog        : TStringList;  { v14.1: per-channel ownership/transform diag }
  chanXfmCount   : Integer;
  chanOwnCount   : Integer;
  diagPath       : String;
  diagBreakdown  : String;

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
  preCX, preCY, newPreCX, newPreCY : TCoord;
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

  { ---- Step 7a.5: Classify free primitives by nearest channel ----
    v14 fix for the bbox-overlap cross-claim hazard. With tightly-packed
    pre-script channels, bbox+margin windows overlap and the spatial
    iterator for channel i can grab primitives that visually belong to
    channel j. DoneSet dedupes -- but to the first claimant, not the right
    one. Pre-classifying every free primitive by nearest channel center
    (and confirming it's inside that channel's bbox+margin) gives a stable
    per-primitive owner; the polar step then transforms each primitive in
    exactly one channel iteration. }
  OwnerMap := TStringList.Create;
  BuildPrimitiveOwnership(Board, PreBBoxes, OwnerMap);

  { v14.1 diagnostic: per-channel breakdown of ownership + transform.
    Format per line: 'i  ChanName  owned=NNNN  xformed=NNNN'. Channel 0
    (reference) has xformed=- because the polar loop skips it. }
  DiagLog := TStringList.Create;
  DiagLog.Add('=== PolarChannelArray v14.1 diagnostic ===');
  DiagLog.Add('Date/time: ' + DateTimeToStr(Now));
  DiagLog.Add('Channels detected: ' + IntToStr(ChanNames.Count));
  DiagLog.Add('OwnerMap total entries: ' + IntToStr(OwnerMap.Count));
  DiagLog.Add('');
  DiagLog.Add('chanIdx  ClassName       owned    xformed');

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

  { v14.1: log channel 0 (reference, owned but not transformed) before loop }
  chanOwnCount := CountOwnedByChannel(OwnerMap, 0);
  DiagLog.Add('0        ' + ChanNames[0] + '    ' + IntToStr(chanOwnCount) + '    - (ref)');

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

    { Free primitives: pulled from the pre-reset bbox snapshot, because
      the reset step did not move free primitives. The spatial query
      region is the channel's original (pre-script) bbox; the rotation
      pivot is the original bbox centre (so the internal cluster geometry
      stays intact through rotation). v14 fix: the TRANSLATION target is
      newCX/newCY (where the components landed) -- NOT newPreCX/newPreCY
      (where the pre-script cluster centre rotates to). The two differ by
      the radial offset (refCX,refCY)<->(preCX,preCY), and using
      newPreCX/newPreCY left primitives on a different ring from their
      components. Channels are identical by multi-channel compile, so
      primitive-offset-from-preCX == component-offset-from-refCX --
      translating to newCX/newCY aligns them. }
    GetBBoxFromSnapshot(PreBBoxes, i,
                        preMinX, preMinY, preMaxX, preMaxY,
                        preCX, preCY, preCount);
    chanXfmCount := 0;
    if preCount > 0 then
    begin
      margin := ComputeMargin(preMinX, preMinY, preMaxX, preMaxY);
      chanXfmCount := TransformChannelFreePrimitives(Board, DoneSet, OwnerMap, i,
                                      preMinX, preMinY, preMaxX, preMaxY, margin,
                                      preCX, preCY, newCX, newCY, rotateDeg);
    end;

    { v14.1 diagnostic line for this channel }
    chanOwnCount := CountOwnedByChannel(OwnerMap, i);
    DiagLog.Add(IntToStr(i) + '        ' + ChanNames[i] +
                '    ' + IntToStr(chanOwnCount) +
                '    ' + IntToStr(chanXfmCount));
  end;

  PCBServer.PostProcess;

  Board.GraphicallyInvalidate;

  { v14.1 diagnostic: write the per-channel breakdown to a log file
    alongside the project, and include the first chunk in the dialog.
    Verbose dialog is bounded to ~13 channel lines so it stays usable. }
  DiagLog.Add('');
  DiagLog.Add('Total DoneSet transforms: ' + IntToStr(DoneSet.Count));
  DiagLog.Add('Reset matched components: ' + IntToStr(resetMatched));

  { Build project-directory path by scanning Board.FileName backwards
    for '\'. ExtractFilePath is not in the verified corpus on this build
    -- the manual scan is the verified pattern (see
    PolarChannelArray-Diagnostic.pas:916-921). }
  diagPath := Board.FileName;
  i := Length(diagPath);
  while (i > 0) and (diagPath[i] <> '\') do i := i - 1;
  diagPath := Copy(diagPath, 1, i);
  if diagPath = '' then diagPath := 'C:\Temp\';
  diagPath := diagPath + 'polar-array-v14.log';
  try
    DiagLog.SaveToFile(diagPath);
  except
    diagPath := '(failed to write log)';
  end;

  { Build a compact breakdown string for the dialog (one line per channel) }
  diagBreakdown := '';
  for i := 5 to DiagLog.Count - 4 do
    diagBreakdown := diagBreakdown + DiagLog[i] + #13#10;

  ShowMessage('Done: ' + IntToStr(N) + ' channels arranged on a ' +
              FloatToStrF(refR_mm, ffFixed, 10, 3) + ' mm radius circle.' + #13#10 +
              IntToStr(DoneSet.Count) + ' free primitives transformed.' + #13#10 +
              'Reset snapped ' + IntToStr(resetMatched) + ' components to reference.' + #13#10 +
              'Reference ' + ChanNames[0] + ' was not moved.' + #13#10 + #13#10 +
              'Per-channel breakdown (owned vs xformed):' + #13#10 +
              diagBreakdown + #13#10 +
              'Log: ' + diagPath + #13#10 + #13#10 +
              'Next: Tools > Polygon Pours > Repour All, then run DRC.');

  DoneSet.Free;
  PreBBoxes.Free;
  OwnerMap.Free;
  DiagLog.Free;
  ChanNames.Free;
end;
