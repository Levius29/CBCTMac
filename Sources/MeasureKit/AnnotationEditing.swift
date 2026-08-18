import DICOMCore

// Correggere un'annotazione già posata.
//
// # Il difetto che questo chiude
//
// `handlesMM` esisteva da sempre — «punti manipolabili dall'utente», dice la sua
// documentazione — e nessuno li manipolava. Una misura posata un millimetro più in là andava
// cancellata e rifatta da capo, e su un angolo a tre punti significava rifarne tre. In qualunque
// visore le maniglie di una misura si trascinano, ed è la prima cosa che si prova a fare.
//
// # Perché uno spostamento non è uguale per tutte
//
// Perché una maniglia non è sempre un vertice. Sull'ellisse la prima è il centro e le altre due
// sono gli estremi dei semiassi: trascinare il centro sposta la figura intera, trascinare un
// estremo ne cambia una misura sola. Sulla sfera la seconda maniglia definisce il raggio, non
// una posizione. Trattarle tutte come vertici darebbe forme che si deformano in modi che nessuno
// si aspetta — un'ellisse che perde la perpendicolarità degli assi, una sfera che smette di
// essere una sfera.

extension Annotation {

    /// Sposta la maniglia indicata su un nuovo punto, restituendo l'annotazione corretta.
    ///
    /// Un indice fuori intervallo lascia tutto com'è: chi chiama lo ricava da un test di
    /// prossimità, e un difetto lì deve dare un gesto inerte, non una forma stravolta.
    public func movingHandle(at index: Int, toMM pointMM: Vec3) -> Annotation {
        guard index >= 0, index < handlesMM.count, pointMM.isFinite else { return self }

        switch self {
        case .distance(var measurement):
            if index == 0 { measurement.startMM = pointMM } else { measurement.endMM = pointMM }
            return .distance(measurement)

        case .angle(var measurement):
            // L'ordine di `handlesMM` è primo braccio, vertice, secondo braccio: il vertice sta
            // **in mezzo** perché è così che si legge un angolo disegnato, non perché sia il
            // primo dato del tipo.
            switch index {
            case 0: measurement.firstArmMM = pointMM
            case 1: measurement.vertexMM = pointMM
            default: measurement.secondArmMM = pointMM
            }
            return .angle(measurement)

        case .ellipseROI(var roi):
            if index == 0 { return translated(by: pointMM - roi.centerMM) }
            // Gli estremi dei semiassi scorrono **lungo il proprio asse**: si cambia una misura,
            // non l'orientamento. Lasciando libero il punto i due semiassi smetterebbero di
            // essere perpendicolari, e l'area calcolata non descriverebbe più la figura disegnata.
            let offset = pointMM - roi.centerMM
            if index == 1 {
                guard let unit = roi.semiAxisAMM.normalized else { return self }
                roi.semiAxisAMM = unit * offset.dot(unit)
            } else {
                guard let unit = roi.semiAxisBMM.normalized else { return self }
                roi.semiAxisBMM = unit * offset.dot(unit)
            }
            return .ellipseROI(roi)

        case .polygonROI(var roi):
            roi.verticesMM[index] = pointMM
            return .polygonROI(roi)

        case .sphereROI(var roi):
            if index == 0 { return translated(by: pointMM - roi.centerMM) }
            // La seconda maniglia definisce il **raggio**: conta quanto dista dal centro, non
            // dove sta attorno.
            roi.radiusMM = max(roi.centerMM.distance(to: pointMM), 1e-6)
            return .sphereROI(roi)

        case .profileLine(var line):
            if index == 0 { line.startMM = pointMM } else { line.endMM = pointMM }
            return .profileLine(line)

        case .text(var note):
            note.anchorMM = pointMM
            return .text(note)

        case .arrow(var note):
            // L'ordine è punta, coda: la punta è ciò che si indica ed è il primo dato del tipo.
            if index == 0 { note.tipMM = pointMM } else { note.tailMM = pointMM }
            return .arrow(note)

        case .freehand(var path):
            path.pointsMM[index] = pointMM
            return .freehand(path)

        case .polyline(var measurement):
            measurement.pointsMM[index] = pointMM
            return .polyline(measurement)

        case .lineAngle(var measurement):
            switch index {
            case 0: measurement.firstStartMM = pointMM
            case 1: measurement.firstEndMM = pointMM
            case 2: measurement.secondStartMM = pointMM
            default: measurement.secondEndMM = pointMM
            }
            return .lineAngle(measurement)
        }
    }

    /// Sposta l'annotazione intera.
    ///
    /// Passa da `transform(point:vector:)`, che è già l'unico posto in cui si distingue ciò che
    /// va traslato da ciò che no: i semiassi di un'ellisse sono **vettori** e una traslazione non
    /// li tocca, mentre i suoi vertici sono punti. Rifare qui la distinzione significherebbe
    /// dover ricordare quella regola in due posti.
    public func translated(by offsetMM: Vec3) -> Annotation {
        var copy = self
        copy.transform(point: { $0 + offsetMM }, vector: { $0 })
        return copy
    }

    /// La maniglia più vicina a un punto, se entro la tolleranza.
    ///
    /// - Returns: indice della maniglia e sua distanza, per poter scegliere fra più annotazioni
    ///   sovrapposte quella davvero più vicina.
    public func nearestHandle(to pointMM: Vec3, toleranceMM: Double) -> (index: Int, distanceMM: Double)? {
        var best: (index: Int, distanceMM: Double)?
        for (index, handle) in handlesMM.enumerated() {
            let distance = handle.distance(to: pointMM)
            guard distance <= toleranceMM else { continue }
            if best == nil || distance < best!.distanceMM {
                best = (index, distance)
            }
        }
        return best
    }
}
