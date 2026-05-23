{ ===========================================================================
  PolarPolygonProbe2.pas

  Probe-2 in the polygon API discovery sequence. Probe-1 confirmed
  ePolyObject=10, eRegionObject=11, and the verified accessors
  (Layer, BoundingRectangle, Component, ObjectId).

  This probe adds ONE new accessor: Poly.PointCount.

  Rationale: per [[feedback-probe-first-for-unverified-apis]] +
  [[feedback-delphiscript-on-ad26]] -- DelphiScript on AD26 resolves
  property accesses at compile time, so try/except cannot catch an
  unknown property. To minimise blast radius, each probe tests ONE new
  accessor. If PointCount is wrong on this build, only this probe
  fails; probe-1's results remain valid and we adjust.

  If this probe compiles + runs + returns sane integers (>= 3 for any
  closed polygon outline), Poly.PointCount is verified. The follow-up
  probe will test PointX[i] / PointY[i].

  Output: C:\Users\Public\PolarPolygonProbe2.txt
=========================================================================== }

function P2_Fmt(c : TCoord) : String;
begin
  Result := FloatToStrF(CoordToMMs(c), ffFixed, 12, 4);
end;

function P2_LayerName(Board : IPCB_Board; layer : Integer) : String;
begin
  Result := IntToStr(layer);
  try
    Result := IntToStr(layer) + ':' + Board.LayerName(layer);
  except
  end;
end;

procedure RunPolygonProbe2;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Prim  : IPCB_Primitive;
  Poly  : IPCB_Polygon;
  Lines : TStringList;
  outFile : String;
  totalPoly, emitted : Integer;
  pointCount : Integer;
  bbCX, bbCY : TCoord;
begin
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.');
    Exit;
  end;

  Lines := TStringList.Create;
  Lines.Add('=== Polar Polygon Probe 2 ===');
  Lines.Add('Generated : ' + DateTimeToStr(Now));
  Lines.Add('Board     : ' + Board.FileName);
  Lines.Add('');
  Lines.Add('Tests ONE new accessor: IPCB_Polygon.PointCount.');
  Lines.Add('If this probe compiles + runs successfully, PointCount is');
  Lines.Add('verified on this AD26 build.');
  Lines.Add('');

  totalPoly := 0;
  emitted := 0;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(ePolyObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    if Prim.ObjectId = ePolyObject then
    begin
      totalPoly := totalPoly + 1;
      Poly := Prim;

      { THE TEST. If Poly.PointCount is not a valid property on AD26,
        this probe fails at compile time. If it returns a Variant or
        invalid type, this probe fails at runtime. Wrap in try/except
        purely to convert runtime failure into a flagged row instead
        of an abort. }
      pointCount := -1;
      try
        pointCount := Poly.PointCount;
      except
        pointCount := -1;
      end;

      bbCX := (Prim.BoundingRectangle.Left + Prim.BoundingRectangle.Right) div 2;
      bbCY := (Prim.BoundingRectangle.Bottom + Prim.BoundingRectangle.Top) div 2;

      if emitted < 100 then
      begin
        Lines.Add('POLY[' + IntToStr(totalPoly) + ']' +
                  '  layer=' + P2_LayerName(Board, Prim.Layer) +
                  '  bboxCX=' + P2_Fmt(bbCX) + 'mm' +
                  '  bboxCY=' + P2_Fmt(bbCY) + 'mm' +
                  '  PointCount=' + IntToStr(pointCount));
        emitted := emitted + 1;
      end;
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  Lines.Add('');
  Lines.Add('-- Summary --');
  Lines.Add('  polygons enumerated      : ' + IntToStr(totalPoly));
  Lines.Add('  emitted (cap 100)        : ' + IntToStr(emitted));
  Lines.Add('');
  Lines.Add('-- Interpretation --');
  Lines.Add('  All polygons should have PointCount >= 3 (closed outline).');
  Lines.Add('  If PointCount = -1 -> property exists but raised at runtime.');
  Lines.Add('  If this probe failed to compile -> property name is wrong on');
  Lines.Add('  AD26; alternatives to try in probe-2b: Poly.PointsCount,');
  Lines.Add('  Poly.GetState_PointCount, Poly.Geometry.PointCount.');
  Lines.Add('');
  Lines.Add('  Next probe (probe-3): if PointCount is verified, test');
  Lines.Add('  Poly.PointX[i] / Poly.PointY[i] indexed access.');

  outFile := 'C:\Users\Public\PolarPolygonProbe2.txt';
  Lines.SaveToFile(outFile);
  Lines.Free;

  ShowMessage('Probe 2 complete. Output: ' + outFile);
end;

begin
  RunPolygonProbe2;
end.
