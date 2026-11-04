"""テスト仕様書を spec_data.py から作る。

    python tool/test_spec/build.py   # openpyxl が要る

出力: docs/テスト仕様書.xlsx（コース配布のひな形と同じ 6 列 + 確認方法・根拠・Redmine）と
docs/10_test_spec.md（同じ内容の Markdown）。
"""
import collections
import os
import sys

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import spec_data as d  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
XLSX = os.path.join(ROOT, 'docs', 'テスト仕様書.xlsx')
MD = os.path.join(ROOT, 'docs', '10_test_spec.md')

HEADERS = ['番号', 'カテゴリ', '適用', 'テスト項目', '期待される結果', 'テスト結果', '確認方法・根拠', 'Redmine']
WIDTHS = [6, 9, 12, 44, 40, 30, 34, 12]
SHEETS = [('単体テスト', 'U', d.UNIT), ('結合テスト', 'I', d.INTEGRATION), ('総合テスト', 'S', d.SYSTEM)]

thin = Side(style='thin', color='000000')
BORDER = Border(left=thin, right=thin, top=thin, bottom=thin)
WRAP = Alignment(wrap_text=True, vertical='top')
BOLD = Font(bold=True)
HEAD_FILL = PatternFill('solid', fgColor='DDEBF7')
OK_FILL = PatternFill('solid', fgColor='E2EFDA')
TODO_FILL = PatternFill('solid', fgColor='FFF2CC')
NG_FILL = PatternFill('solid', fgColor='F8CBAD')


def status(result):
    if result.startswith('OK'):
        return 'OK'
    if result.startswith('NG'):
        return 'NG'
    return '未実施'


def counts(rows):
    c = collections.Counter(status(r[4]) for r in rows)
    return c['OK'], c['NG'], c['未実施']


def write_table(ws, headers, widths, rows, fills=None):
    for i, (h, w) in enumerate(zip(headers, widths), start=1):
        cell = ws.cell(row=1, column=i, value=h)
        cell.font = BOLD
        cell.border = BORDER
        cell.alignment = Alignment(wrap_text=True, vertical='center')
        cell.fill = HEAD_FILL
        ws.column_dimensions[get_column_letter(i)].width = w
    for r, row in enumerate(rows, start=2):
        for c, value in enumerate(row, start=1):
            cell = ws.cell(row=r, column=c, value=value)
            cell.border = BORDER
            cell.alignment = WRAP
        if fills:
            fills(ws, r, row)
    ws.freeze_panes = 'A2'
    ws.auto_filter.ref = f'A1:{get_column_letter(len(headers))}{len(rows) + 1}'


def color_result(ws, r, row):
    s = status(row[5])
    ws.cell(row=r, column=6).fill = {'OK': OK_FILL, 'NG': NG_FILL}.get(s, TODO_FILL)


def build_xlsx():
    wb = Workbook()
    ws = wb.active
    ws.title = '説明'
    ws['A1'] = d.TITLE
    ws['A1'].font = Font(bold=True, size=14)
    ws['A2'] = d.VERSION
    row = 4
    for k, v in d.OVERVIEW:
        ws.cell(row=row, column=1, value=k).font = BOLD
        ws.cell(row=row, column=2, value=v).alignment = WRAP
        row += 1
    row += 1
    ws.cell(row=row, column=1, value='結果のまとめ').font = BOLD
    row += 1
    for i, h in enumerate(['シート', '項目数', 'OK', 'NG', '未実施'], start=1):
        c = ws.cell(row=row, column=i, value=h)
        c.font = BOLD
        c.border = BORDER
        c.fill = HEAD_FILL
    for name, _, rows in SHEETS:
        row += 1
        ok, ng, todo = counts(rows)
        for i, v in enumerate([name, len(rows), ok, ng, todo], start=1):
            ws.cell(row=row, column=i, value=v).border = BORDER
    ws.column_dimensions['A'].width = 14
    ws.column_dimensions['B'].width = 100
    for col in 'CDE':
        ws.column_dimensions[col].width = 10

    for name, prefix, rows in SHEETS:
        sheet = wb.create_sheet(name)
        table = [[f'{prefix}{i}', *r] for i, r in enumerate(rows, start=1)]
        write_table(sheet, HEADERS, WIDTHS, table, color_result)

    data = wb.create_sheet('テストデータ')
    write_table(data, ['番号', '名前', '内容（量・質）', '作り方', '使うテスト'],
                [7, 16, 50, 40, 36], [list(r) for r in d.TEST_DATA])
    wb.save(XLSX)


def md_escape(s):
    return str(s).replace('|', '｜').replace('\n', ' ')


def build_md():
    out = [f'# {d.TITLE}', '', d.VERSION + '。Excel 版は [テスト仕様書.xlsx](テスト仕様書.xlsx)（同じ内容、`tool/test_spec/build.py` で作る）。', '']
    out += ['## 説明', '']
    for k, v in d.OVERVIEW:
        out.append(f'- **{k}**: {v}')
    out += ['', '## 結果のまとめ', '', '| シート | 項目数 | OK | NG | 未実施 |', '|---|---|---|---|---|']
    for name, _, rows in SHEETS:
        ok, ng, todo = counts(rows)
        out.append(f'| {name} | {len(rows)} | {ok} | {ng} | {todo} |')
    for name, prefix, rows in SHEETS:
        out += ['', f'## {name}', '', '| ' + ' | '.join(HEADERS) + ' |', '|' + '---|' * len(HEADERS)]
        for i, r in enumerate(rows, start=1):
            out.append('| ' + ' | '.join(md_escape(x) for x in [f'{prefix}{i}', *r]) + ' |')
    out += ['', '## テストデータ', '', '| 番号 | 名前 | 内容（量・質） | 作り方 | 使うテスト |', '|---|---|---|---|---|']
    for r in d.TEST_DATA:
        out.append('| ' + ' | '.join(md_escape(x) for x in r) + ' |')
    out.append('')
    with open(MD, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out))


if __name__ == '__main__':
    build_xlsx()
    build_md()
    for name, _, rows in SHEETS:
        print(name, len(rows), counts(rows))
