import Foundation
import ImplantKit
import MeshKit

// Le mesh degli oggetti del piano, costruite una volta e non a ogni fotogramma.
//
// # Il guasto che toglie di mezzo
//
// La sovraimpressione del riquadro 3D costruiva le mesh **dentro il disegno**. Ogni fotogramma,
// per ogni impianto, barra e canale: ricampionare la spline, generare le fasce, e solo dopo
// proiettare e ordinare i triangoli. Su due canali mandibolari significa ottomila triangoli
// rigenerati sessanta volte al secondo, sul thread principale, nel mezzo di una rotazione.
//
// Il sintomo non era «lento» e basta: era che **il nervo si spostava più piano del volume**. Il
// volume lo disegna Metal, che regge il passo; la sovraimpressione la disegna SwiftUI, che non
// ce la faceva, e i due disegni si staccavano di qualche fotogramma. Un piano che si sfalda
// mentre lo si gira.
//
// # Perché una cache e non un ricalcolo agli eventi giusti
//
// Perché gli eventi giusti sono tanti — posare, trascinare, annullare, caricare un piano,
// cambiare modello implantare — e ne basta uno dimenticato per disegnare la forma di ieri. La
// chiave qui è il **valore** dell'oggetto: tutti conformi a `Hashable`, quindi se qualcosa è
// cambiato la chiave cambia e la mesh si rifà. Non c'è niente da ricordarsi di invalidare.
//
// # Perché non è stato osservato
//
// Perché la cache si riempie **durante il disegno**, e scrivere stato osservato mentre una
// vista si sta costruendo la fa invalidare nel mezzo — è la stessa trappola documentata su
// `cephTracing`. Una classe fuori dall'osservazione si può riempire pigramente senza che
// SwiftUI se ne accorga, che è esattamente ciò che serve a una cache.
@MainActor
final class SolidMeshCache {

    private struct Entry {
        let key: Int
        let mesh: Mesh
    }

    private var entries: [UUID: Entry] = [:]

    /// La mesh dell'oggetto, ricostruita solo se l'oggetto è cambiato.
    ///
    /// - Parameter key: il valore da cui la forma dipende. Non basta l'identificatore: quello
    ///   resta uguale mentre l'impianto si trascina, ed è proprio allora che la forma cambia.
    func mesh(id: UUID, key: Int, build: () -> Mesh) -> Mesh {
        if let entry = entries[id], entry.key == key {
            return entry.mesh
        }
        let mesh = build()
        entries[id] = Entry(key: key, mesh: mesh)
        // Gli oggetti cancellati lascerebbero la loro mesh qui per sempre. Si sfoltisce quando
        // la cache cresce oltre il ragionevole: un piano non ha cento oggetti solidi, e se ce
        // ne sono cento sono le briciole di quelli tolti.
        if entries.count > 64 { entries.removeAll() }
        return mesh
    }

    /// Svuota la cache. Da chiamare aprendo un altro volume, dove niente di quel che c'era vale.
    func clear() { entries.removeAll() }
}
