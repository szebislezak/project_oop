import tkinter as tk
from tkinter import messagebox
from datetime import datetime

class Szoba:
    def __init__(self, szobaszam, ar):
        self.szobaszam = szobaszam
        self.ar = ar

class EgyagyasSzoba(Szoba):
    def __init__(self, szobaszam):
        super().__init__(szobaszam, 50000)

class KetagyasSzoba(Szoba):
    def __init__(self, szobaszam):
        super().__init__(szobaszam, 80000)

class Szalloda:
    def __init__(self, nev):
        self.nev = nev
        self.szobak = []
        self.foglalasok = []

    def add_szoba(self, szoba):
        self.szobak.append(szoba)

    def foglalas(self, szobaszam, datum):
        for foglalas in self.foglalasok:
            if foglalas['szobaszam'] == szobaszam and foglalas['datum'] == datum:
                return "A foglalás sikertelen. A szoba már foglalt ekkor."

        for szoba in self.szobak:
            if szoba.szobaszam == szobaszam:
                self.foglalasok.append({'szobaszam': szobaszam, 'datum': datum})
                return szoba.ar

        return "Nincs ilyen szoba."

    def lemondas(self, szobaszam, datum):
        for foglalas in self.foglalasok:
            if foglalas['szobaszam'] == szobaszam and foglalas['datum'] == datum:
                self.foglalasok.remove(foglalas)
                return "A foglalás sikeresen törölve."
        return "Nincs ilyen foglalás."

    def listaz_foglalasok(self):
        if not self.foglalasok:
            return "Nincsenek foglalások."
        foglalasok_str = "Foglalások:\n"
        for foglalas in self.foglalasok:
            foglalasok_str += f"Szobaszám: {foglalas['szobaszam']}, Dátum: {foglalas['datum']}\n"
        return foglalasok_str

def foglalas_callback(szalloda, szobaszam_input, datum_input, status_label):
    szobaszam = szobaszam_input.get()
    datum = datum_input.get()
    try:
        datum_obj = datetime.strptime(datum, "%Y-%m-%d")
        if datum_obj < datetime.now():
            messagebox.showerror("Hiba", "Hibás dátum: csak jövőbeni foglalás lehetséges.")
            return
        ar = szalloda.foglalas(szobaszam, datum)
        messagebox.showinfo("Foglalás", f"A foglalás sikeres. Ár: {ar}")
        status_label.config(text="Foglalás sikeres.")
    except ValueError:
        messagebox.showerror("Hiba", "Hibás dátum formátum.")

def lemondas_callback(szalloda, szobaszam_input, datum_input, status_label):
    szobaszam = szobaszam_input.get()
    datum = datum_input.get()
    lemondas_eredmeny = szalloda.lemondas(szobaszam, datum)
    messagebox.showinfo("Lemondás", lemondas_eredmeny)
    status_label.config(text="Foglalás törölve.")

def listaz_callback(szalloda):
    foglalasok = szalloda.listaz_foglalasok()
    messagebox.showinfo("Foglalások", foglalasok)

def main():
    szalloda = Szalloda("Példa Szálloda")
    szalloda.add_szoba(EgyagyasSzoba("101"))
    szalloda.add_szoba(KetagyasSzoba("102"))
    szalloda.add_szoba(EgyagyasSzoba("103"))
    szalloda.add_szoba(KetagyasSzoba("104"))
    szalloda.add_szoba(KetagyasSzoba("105"))
    szalloda.add_szoba(KetagyasSzoba("106"))
    szalloda.add_szoba(KetagyasSzoba("107"))
    szalloda.add_szoba(KetagyasSzoba("108"))
    szalloda.add_szoba(KetagyasSzoba("109"))
    szalloda.add_szoba(KetagyasSzoba("110"))
    szalloda.add_szoba(KetagyasSzoba("111"))
    szalloda.add_szoba(KetagyasSzoba("112"))
    szalloda.add_szoba(KetagyasSzoba("113"))
    szalloda.add_szoba(KetagyasSzoba("114"))
    szalloda.add_szoba(KetagyasSzoba("115"))
    szalloda.add_szoba(KetagyasSzoba("116"))

    root = tk.Tk()
    root.title("Szálloda Foglalások")

    root.configure(bg="wheat")

    szobaszam_label = tk.Label(root, text="Szobaszám:", font=("wheat", 12), fg="dimgrey")
    szobaszam_label.grid(row=0, column=0)
    szobaszam_input = tk.Entry(root)
    szobaszam_input.grid(row=0, column=1)

    datum_label = tk.Label(root, text="Dátum (év-hó-nap):", font=("Wheat", 12), fg="dimgrey")
    datum_label.grid(row=1, column=0)
    datum_input = tk.Entry(root)
    datum_input.grid(row=1, column=1)

    foglalas_button = tk.Button(root, text="Foglalás", command=lambda: foglalas_callback(szalloda, szobaszam_input, datum_input, status_label), bg="springgreen", fg="white", font=("Helvetica", 12))
    foglalas_button.grid(row=2, column=0)

    lemondas_button = tk.Button(root, text="Lemondás", command=lambda: lemondas_callback(szalloda, szobaszam_input, datum_input, status_label), bg="red", fg="white", font=("Helvetica", 12))
    lemondas_button.grid(row=2, column=1)

    listaz_button = tk.Button(root, text="Foglalások listázása", command=lambda: listaz_callback(szalloda), font=("Helvetica", 12))
    listaz_button.grid(row=3, column=0, columnspan=2)

    exit_button = tk.Button(root, text="Kilépés", command=root.quit, font=("Helvetica", 12))
    exit_button.grid(row=4, column=0, columnspan=2)

    status_label = tk.Label(root, text="", bd=1, relief=tk.SUNKEN, anchor=tk.W)
    status_label.grid(row=5, column=0, columnspan=2, sticky=tk.W+tk.E)

    root.mainloop()

if __name__ == "__main__":
    main()
