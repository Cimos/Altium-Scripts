{ ===========================================================================
  PolarPolygonProbe.pas

  Read-only probe to map the actual AD26 API surface for IPCB_Polygon and
  IPCB_Region primitives. The polar array script does not currently move
  these primitives (bench-observed orphan trapezoidal wireframes 2026-05-23);
  before adding handling we need verified accessors per
  [[feedback-probe-first-for-unverified-apis]] + [[feedback-delphiscript-on-ad26]].

  Past AI-generated code has fabricated polygon-state identifiers
  (IPCB_Polygon.PolygonState, ePolyState_* enum -- explicitly called out as
  fabrications in agent-context/core.md line 22). This probe deliberately
  sticks to accessors that ARE verified across the corpus (Layer,
  BoundingRectangle, Component, ObjectId) and AVOIDS speculative ones.

  If this probe fails to compile, the failure points to the unverified
  constant. Most likely candidates:
    - ePolyObject     (assumed valid; if not, replace with the numeric
                       ObjectId and re-run -- or fall back to a separate
                       probe that enumerates ALL primitives).
    - eRegionObject   (same).

  Output: C:\Users\Public\PolarPolygonProbe.txt
=========================================================================== }

function P_Fmt(c : TCoord) : String;
begin
  Result := FloatToStrF(CoordToMMs(c), ffFixed, 12, 4);
end;

function P_LayerName(Board : IPCB_Board; layer : Integer) : String;
begin
  Result := IntToStr(layer);
  try
    Result := IntToStr(layer) + ':' + Board.LayerName(layer);
  except
  end;
end;

function P_CompName(Prim : IPCB_Primitive) : String;
var comp : IPCB_Component;
begin
  Result := '(error)';
  try
    comp := Prim.Component;
    if comp = Nil then Result := 'Nil'
    else Result := comp.Name.Text;
  except
    Result := '(error)';
  end;
end;

procedure RunPolygonProbe;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Prim  : IPCB_Primitive;
  Lines : TStringList;
  outFile : String;
  totalPoly, totalRegion, emitted : Integer;
  bbLeft, bbBottom, bbRight, bbTop : TCoord;
  kind : String;
begin
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.');
    Exit;
  end;

  Lines := TStringList.Create;
  Lines.Add('=== Polar Polygon Probe ===');
  Lines.Add('Generated : ' + DateTimeToStr(Now));
  Lines.Add('Board     : ' + Board.FileName);
  Lines.Add('');
  Lines.Add('Goal: enumerate every IPCB_Polygon and IPCB_Region on the');
  Lines.Add('board, dump VERIFIED accessors only (Layer, BoundingRectangle,');
  Lines.Add('Component, ObjectId). Sets the data foundation for the polar');
  Lines.Add('array script''s polygon-mover (next bench cycle).');
  Lines.Add('');

  totalPoly := 0;
  totalRegion := 0;
  emitted := 0;

  { ePolyObject + eRegionObject are UNVERIFIED constants on AD26 as of
    2026-05-23. If this MkSet call fails to compile, the constant names
    are wrong on this build; reply to Simon with the compile error and
    we adjust (try numeric ObjectId scan as fallback). }
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(ePolyObject, eRegionObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    if Prim.ObjectId = ePolyObject then
    begin
      totalPoly := totalPoly + 1;
      kind := 'POLY';
    end
    else if Prim.ObjectId = eRegionObject then
    begin
      totalRegion := totalRegion + 1;
      kind := 'REGION';
    end
    else
      kind := 'UNKNOWN-OID-' + IntToStr(Prim.ObjectId);

    { Cap detailed emit at 500 to avoid runaway output. Summary counts
      still reflect totals. }
    if emitted < 500 then
    begin
      bbLeft   := Prim.BoundingRectangle.Left;
      bbBottom := Prim.BoundingRectangle.Bottom;
      bbRight  := Prim.BoundingRectangle.Right;
      bbTop    := Prim.BoundingRectangle.Top;

      Lines.Add(kind + '[' + IntToStr(totalPoly + totalRegion) + ']' +
                '  objectId=' + IntToStr(Prim.ObjectId) +
                '  layer=' + P_LayerName(Board, Prim.Layer) +
                '  comp=' + P_CompName(Prim) +
                '  bboxL=' + P_Fmt(bbLeft) + 'mm' +
                '  bboxB=' + P_Fmt(bbBottom) + 'mm' +
                '  bboxR=' + P_Fmt(bbRight) + 'mm' +
                '  bboxT=' + P_Fmt(bbTop) + 'mm' +
                '  bboxCX=' + P_Fmt((bbLeft + bbRight) div 2) + 'mm' +
                '  bboxCY=' + P_Fmt((bbBottom + bbTop) div 2) + 'mm');
      emitted := emitted + 1;
    end;

    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  Lines.Add('');
  Lines.Add('-- Summary --');
  Lines.Add('  polygons (ePolyObject)   : ' + IntToStr(totalPoly));
  Lines.Add('  regions  (eRegionObject) : ' + IntToStr(totalRegion));
  Lines.Add('  emitted detail (cap 500) : ' + IntToStr(emitted));
  Lines.Add('');
  Lines.Add('-- Next step --');
  Lines.Add('  Cross-reference the bboxCX/bboxCY values above with the');
  Lines.Add('  channel pre-bboxes from PolarChannelArray-Diagnostic. Any');
  Lines.Add('  polygon/region whose bbox center is inside a non-reference');
  Lines.Add('  channel''s pre-bbox is a candidate to be moved by the');
  Lines.Add('  fixed script.');
  Lines.Add('');
  Lines.Add('  Once we know how many polygons/regions are at-risk and');
  Lines.Add('  what layers they live on, the next probe should test the');
  Lines.Add('  vertex / outline accessors (Poly.PointCount,');
  Lines.Add('  Poly.GetState_PointX/PointY, Poly.Segments, etc.). One');
  Lines.Add('  accessor per probe-pass so a compile-fail on one does');
  Lines.Add('  not kill the others.');

  outFile := 'C:\Users\Public\PolarPolygonProbe.txt';
  Lines.SaveToFile(outFile);
  Lines.Free;

  ShowMessage('Probe complete. Output: ' + outFile);
end;

begin
  RunPolygonProbe;
end.
