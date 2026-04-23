{*******************************************************************************
  PolarChannelArray.pas  -- REVISED v10
  Altium DelphiScript -- Arrange channel "rooms" in a circular (polar) array.

  ================================================================
  WHAT CHANGED FROM v9
  ================================================================
  Reset step is now AUTOMATIC (no longer optional). Before arranging,
  all non-reference channels are always normalised to match the
  reference channel's (first channel, e.g. U_DUTB) internal layout.
  This guarantees a clean starting state on every run, whether it is
  the first run or a repeat run on an already-arranged board.

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

{ ---------------------------------------------------------------------------
  BuildClassInventory
  Walks the board's component classes and builds an informational list
  of 'name (count components)' strings. Used to show the user what's
  available before prompting for a prefix.
--------------------------------------------------------------------------- }
procedure BuildClassInventory(Board : IPCB_Board;
                              List  : TStringList);
var
  Iter : IPCB_BoardIterator;
  Prim : IPCB_Primitive;
  Cls  : IPCB_ObjectClass;
  n    : Integer;
begin
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if Cls.MemberKind = COMP_CLASS_MEMBER_KIND then
    begin
      n := CountClassMembers(Board, Cls);
      { Skip classes with zero members -- noisy }
      if n > 0 then
        List.Add(Cls.Name + '  (' + IntToStr(n) + ' comps)');
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ ---------------------------------------------------------------------------
  GuessCommonPrefix
  Given a list of class names that already match a user prefix, find
  the longest common prefix among them. Used to seed a default prefix
  suggestion for the user.
--------------------------------------------------------------------------- }
function GuessCommonPrefix(Names : TStringList) : String;
var
  i, k, minLen : Integer;
  first, candidate : String;
  allMatch : Boolean;
begin
  Result := '';
  if Names.Count = 0 then Exit;
  if Names.Count = 1 then
  begin
    Result := Names[0];
    Exit;
  end;

  first := Names[0];
  minLen := Length(first);
  for i := 1 to Names.Count - 1 do
    if Length(Names[i]) < minLen then minLen := Length(Names[i]);

  k := 0;
  while k < minLen do
  begin
    candidate := Copy(first, 1, k + 1);
    allMatch := True;
    for i := 1 to Names.Count - 1 do
      if Copy(Names[i], 1, k + 1) <> candidate then
      begin
        allMatch := False;
        Break;
      end;
    if allMatch then k := k + 1 else Break;
  end;
  Result := Copy(first, 1, k);
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

{ --------------------------------------------------------------------------- }
procedure TransformChannelFreePrimitives(Board   : IPCB_Board;
                                         DoneSet : TStringList;
                                         bx1, by1, bx2, by2 : TCoord;
                                         margin  : TCoord;
                                         oldCX, oldCY : TCoord;
                                         newCX, newCY : TCoord;
                                         rotateDeg    : Double);
var
  Iter : IPCB_SpatialIterator;
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
                       bx1, by1, bx2, by2) then
        begin
          key := PrimitiveKey(track);
          if DoneSet.IndexOf(key) < 0 then
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
           PointInRect(via.X, via.Y, bx1, by1, bx2, by2) then
        begin
          key := PrimitiveKey(via);
          if DoneSet.IndexOf(key) < 0 then
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
           PointInRect(arc.XCenter, arc.YCenter, bx1, by1, bx2, by2) then
        begin
          key := PrimitiveKey(arc);
          if DoneSet.IndexOf(key) < 0 then
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

          if PointInRect(fillCX, fillCY, bx1, by1, bx2, by2) then
          begin
            key := PrimitiveKey(Prim);
            if DoneSet.IndexOf(key) < 0 then
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
           PointInRect(txt.XLocation, txt.YLocation, bx1, by1, bx2, by2) then
        begin
          key := PrimitiveKey(txt);
          if DoneSet.IndexOf(key) < 0 then
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
           PointInRect(pad.X, pad.Y, bx1, by1, bx2, by2) then
        begin
          key := PrimitiveKey(pad);
          if DoneSet.IndexOf(key) < 0 then
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
  StripChannelSuffix
  Removes the channel suffix from a designator. The suffix is the channel
  class name preceded by an underscore, e.g.:
    Designator "C1_U_DUTB", class "U_DUTB" -> "C1"
    Designator "R3_U_DUTC", class "U_DUTC" -> "R3"
  If the designator doesn't end with the suffix, returns the designator
  unchanged. Case-insensitive.
--------------------------------------------------------------------------- }
function StripChannelSuffix(designator, className : String) : String;
var
  suffix : String;
  desigLen, suffLen : Integer;
begin
  suffix := '_' + className;
  desigLen := Length(designator);
  suffLen := Length(suffix);
  if (desigLen >= suffLen) and
     (AnsiUpperCase(Copy(designator, desigLen - suffLen + 1, suffLen)) =
      AnsiUpperCase(suffix)) then
    Result := Copy(designator, 1, desigLen - suffLen)
  else
    Result := designator;
end;

{ ---------------------------------------------------------------------------
  FindMatchingComponent
  Looks through the given class for a component whose "root" designator
  (stripped of the class suffix) matches the target root. Returns Nil if
  not found.
--------------------------------------------------------------------------- }
function FindMatchingComponent(Board : IPCB_Board;
                               Cls : IPCB_ObjectClass;
                               className : String;
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
      root := StripChannelSuffix(Comp.Name.Text, className);
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
begin
  matched := 0;

  { For each non-reference channel }
  for i := 1 to ChanNames.Count - 1 do
  begin
    otherClsName := ChanNames[i];
    otherCls := FindClassByName(Board, otherClsName);
    if otherCls = Nil then Continue;

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
        root := StripChannelSuffix(Comp.Name.Text, otherClsName);
        refComp := FindMatchingComponent(Board, RefCls, RefClsName, root);
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

  Result := matched;
end;

{ ===========================================================================
  ENTRY POINT
=========================================================================== }
procedure ArrangeChannelsInPolarArray;
var
  Board     : IPCB_Board;
  Cls       : IPCB_ObjectClass;

  ClassInventory : TStringList;  { all channel-style classes on this board }
  ChanNames      : TStringList;  { names that match the chosen prefix }
  DoneSet        : TStringList;

  i, N, compCount : Integer;
  invMessage, prefix, defPrefix, inputStr : String;
  cx_mm, cy_mm : Double;
  CX, CY    : TCoord;
  rotateDeg : Double;
  newCX, newCY, oldCX, oldCY : TCoord;
  minX, minY, maxX, maxY, margin : TCoord;
  refCX, refCY : TCoord;
  refR_mm : Double;
  summary : String;
  resetMatched : Integer;
begin
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.');
    Exit;
  end;

  { ---- Step 1: Inventory all component classes on the board ---- }
  ClassInventory := TStringList.Create;
  ClassInventory.Sorted := True;
  BuildClassInventory(Board, ClassInventory);

  if ClassInventory.Count = 0 then
  begin
    ShowMessage('No component classes found on this board.' + #13#10 +
                'Multi-channel designs are expected to have component classes' + #13#10 +
                'generated from the schematic hierarchy.');
    ClassInventory.Free;
    Exit;
  end;

  { ---- Step 2: Show inventory and ask for prefix ---- }
  invMessage := 'Component classes on this board:' + #13#10 + #13#10;
  for i := 0 to ClassInventory.Count - 1 do
    invMessage := invMessage + '  ' + ClassInventory[i] + #13#10;
  invMessage := invMessage + #13#10 +
                'Enter a PREFIX that matches all channel classes you want' + #13#10 +
                'to arrange (case-insensitive). Example: if you have classes' + #13#10 +
                'U_DUTB, U_DUTC, U_DUTD, enter: U_DUT';

  { Use a guessed prefix as the default to reduce typing on re-runs }
  defPrefix := '';
  if ClassInventory.Count >= 2 then
  begin
    { Get the raw names without the '(N comps)' suffix }
    ChanNames := TStringList.Create;
    for i := 0 to ClassInventory.Count - 1 do
    begin
      inputStr := ClassInventory[i];
      { Strip '  (N comps)' suffix }
      if Pos('  (', inputStr) > 0 then
        inputStr := Copy(inputStr, 1, Pos('  (', inputStr) - 1);
      ChanNames.Add(inputStr);
    end;
    defPrefix := GuessCommonPrefix(ChanNames);
    ChanNames.Free;
  end;

  prefix := InputBox('Polar Channel Array - Select Prefix',
                     invMessage, defPrefix);
  if Trim(prefix) = '' then
  begin
    ClassInventory.Free;
    Exit;
  end;

  ClassInventory.Free;

  { ---- Step 3: Collect matching classes ---- }
  ChanNames := TStringList.Create;
  ChanNames.Sorted := True;
  ChanNames.Duplicates := dupIgnore;

  CollectMatchingClasses(Board, prefix, ChanNames);

  N := ChanNames.Count;
  if N < 2 then
  begin
    ShowMessage('Only ' + IntToStr(N) + ' channel(s) matched prefix "' +
                prefix + '".' + #13#10 +
                'Need at least 2 to form a polar array.');
    ChanNames.Free;
    Exit;
  end;

  { ---- Step 4: Ask for origin by interactive click ----
    Board.ChooseLocation puts Altium into crosshair mode with a status-bar
    prompt. The user clicks on the polar centre (snapping to their polar
    grid if one is enabled). If the user presses Escape, ChooseLocation
    returns False and we fall back to typed input defaulting to (0, 0). }
  if MessageDlg(
       'Next: click the polar origin point on the PCB.' + #13#10 + #13#10 +
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

  { ---- Step 5: Measure reference channel ---- }
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

  { ---- Step 6: Reset always runs ----
    All non-reference channels are normalised to match the reference
    channel (ChanNames[0], e.g. U_DUTB) before the polar array is
    applied. This guarantees a clean starting state on every run. }
  resetMatched := 0;

  { ---- Step 7: Confirmation ---- }
  summary := 'Polar Channel Array -- Summary' + #13#10 + #13#10 +
             'Matched prefix: "' + prefix + '"' + #13#10 +
             'Channel count: ' + IntToStr(N) + #13#10 +
             'Channels (sorted): ';
  for i := 0 to N - 1 do
  begin
    if i > 0 then summary := summary + ', ';
    summary := summary + ChanNames[i];
  end;
  summary := summary + #13#10 + #13#10;

  summary := summary +
             'Reset: ENABLED (all channels will snap to reference first)' + #13#10 + #13#10;

  summary := summary +
             'Reference (unmoved): ' + ChanNames[0] + #13#10 +
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

  { ---- Step 8: Apply reset ---- }
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

  { ---- Step 9: Apply polar transforms ---- }
  DoneSet := TStringList.Create;
  DoneSet.Sorted := True;
  DoneSet.Duplicates := dupIgnore;

  PCBServer.PreProcess;

  { Skip i=0 (reference channel) -- no transformation applied }
  for i := 1 to N - 1 do
  begin
    Cls := FindClassByName(Board, ChanNames[i]);
    if Cls = Nil then Continue;

    ComputeChannelBBox(Board, Cls, minX, minY, maxX, maxY, compCount);
    if compCount = 0 then Continue;

    oldCX  := (minX + maxX) div 2;
    oldCY  := (minY + maxY) div 2;
    margin := ComputeMargin(minX, minY, maxX, maxY);

    rotateDeg := i * (360.0 / N);
    RotatePointXY(refCX, refCY, CX, CY, rotateDeg, newCX, newCY);

    TransformChannelComponents(Board, Cls,
                                oldCX, oldCY, newCX, newCY, rotateDeg);

    TransformChannelFreePrimitives(Board, DoneSet,
                                    minX, minY, maxX, maxY, margin,
                                    oldCX, oldCY, newCX, newCY, rotateDeg);
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
  ChanNames.Free;
end;
